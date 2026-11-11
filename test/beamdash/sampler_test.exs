defmodule Beamdash.SamplerTest do
  use ExUnit.Case, async: false

  alias Beamdash.{AnomalyMonitor, Sampler, Settings, Store, Target}
  alias Beamdash.Test.Fixture

  @node "app@host"
  @monitor :sampler_test_monitor

  defp pid_of(i), do: :erlang.list_to_pid(~c"<0.#{i}.0>")

  defp proc(i, memory, reductions \\ 0) do
    %{
      pid: pid_of(i),
      name: nil,
      initial_call: nil,
      current_function: nil,
      memory: memory,
      message_queue_len: 0,
      reductions: reductions,
      status: :waiting
    }
  end

  defp peers(outlier?) do
    for i <- 10..29 do
      memory = if i == 10 and outlier?, do: 90_000_000, else: 50_000 + i * 100
      Map.merge(proc(i, memory), %{kind: :gen_server, initial_call: {:pool, :init, 1}})
    end
  end

  defp no_details(_pid), do: nil

  # sample number `n`, one second after the previous one
  defp observe(state, procs, n) do
    Sampler.observe(state, procs, n * 1_000, n * 1_000_000, &no_details/1)
  end

  defp run_samples(procs_at) do
    Enum.reduce(procs_at, {Sampler.new(@node), nil}, fn {n, procs}, {state, _} ->
      observe(state, procs, n)
    end)
  end

  defp reasons(rows, reason), do: for(row <- rows, row.reason == reason, do: row)

  test "the first sample has no load, and the top 10 by memory are kept" do
    procs = for i <- 1..12, do: proc(i, i * 100)

    {_state, rows} = observe(Sampler.new(@node), procs, 1)

    assert reasons(rows, :load) == []
    assert length(rows) == 10
    assert Enum.all?(rows, &(&1.reason == :memory))
    assert MapSet.new(rows, & &1.pid) == MapSet.new(for i <- 3..12, do: pid_of(i))
  end

  test "a process busy between two samples is reported as load with its rate" do
    {state, _} = observe(Sampler.new(@node), [proc(1, 100, 0), proc(2, 100, 0)], 1)
    {_state, rows} = observe(state, [proc(1, 100, 0), proc(2, 100, 500_000)], 2)

    [load] = reasons(rows, :load)
    assert load.pid == pid_of(2)
    assert load.data.rate == 500_000
  end

  test "a heap is reported as rising after five consecutive increases, not before" do
    steady = for i <- 2..4, do: proc(i, 100)
    climbing = fn n -> [proc(1, 1_000 + n * 1_000) | steady] end

    {_state, after_five} = run_samples(for n <- 1..5, do: {n, climbing.(n)})
    assert reasons(after_five, :heap_rising) == []

    {_state, after_six} = run_samples(for n <- 1..6, do: {n, climbing.(n)})
    assert [%{pid: pid}] = reasons(after_six, :heap_rising)
    assert pid == pid_of(1)
  end

  test "a snapshot keeps the process fields and the details of the process" do
    details_fun = fn _pid -> %{gc: %{count: 3}} end

    {_state, rows} = Sampler.observe(Sampler.new(@node), [proc(1, 500)], 1, 1, details_fun)

    [row] = rows
    assert row.node == @node
    assert row.data.process.memory == 500
    assert row.data.details == %{gc: %{count: 3}}
  end

  describe "with the store" do
    setup do
      dir = Path.join(System.tmp_dir!(), "beamdash_sampler_#{System.unique_integer([:positive])}")
      store = :"sampler_store_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Store, name: store, path: Path.join(dir, "events.sqlite3"), purge_interval: :infinity}
      )

      on_exit(fn -> File.rm_rf(dir) end)
      :ok = Settings.put_snapshots_enabled(true)
      on_exit(fn -> :ok = Settings.put_snapshots_enabled(false) end)

      %{store: store}
    end

    test "logs are stored once each, in order, as they arrive", ctx do
      {:ok, logs} = Agent.start_link(fn -> [] end)

      name = start_sampler(ctx, connected(logs: fn -> Agent.get(logs, & &1) end))
      ids = fn -> Enum.map(Store.query(:logs, [], ctx.store), & &1.data["id"]) end

      Agent.update(logs, fn _ -> [log(2), log(1)] end)
      :ok = Sampler.tick(name)
      assert ids.() == [2, 1]

      :ok = Sampler.tick(name)
      assert ids.() == [2, 1]

      Agent.update(logs, fn existing -> [log(3) | existing] end)
      :ok = Sampler.tick(name)
      assert ids.() == [3, 2, 1]
    end

    test "details that a JSON encoder cannot take are stored as text", ctx do
      details = fn _pid, _max -> {:ok, %{queue: {:a, pid_of(9)}, owner: pid_of(9)}} end
      name = start_sampler(ctx, connected(details: details))

      :ok = Sampler.tick(name)

      [row] = Store.query(:snapshots, [], ctx.store)
      assert row.data["details"]["queue"] == "{:a, #PID<0.9.0>}"
      assert row.data["details"]["owner"] == "#PID<0.9.0>"
    end

    test "a sample stores the node memory with its 10 largest ETS tables", ctx do
      tables = for i <- 1..12, do: ets_table(i)
      name = start_sampler(ctx, connected(memory: fn _ -> {:ok, memory_snapshot(), tables} end))

      :ok = Sampler.tick(name)

      assert [row] = Store.query(:memory, [], ctx.store)
      assert row.node == @node
      assert row.data["memory"] == %{"total" => 1_000, "processes" => 600}
      assert row.data["atom_count"] == 10
      assert row.data["ets_count"] == 3

      assert length(row.data["tables"]) == 10
      assert Enum.map(row.data["tables"], & &1["name"]) == for(i <- 12..3//-1, do: "table_#{i}")

      assert hd(row.data["tables"]) == %{
               "name" => "table_12",
               "named" => true,
               "type" => "set",
               "size" => 12,
               "memory" => 1200,
               "owner" => "owner"
             }
    end

    test "a failed memory read keeps the snapshots and writes no memory row", ctx do
      name =
        start_sampler(ctx, connected(memory: fn _ -> {:error, {:timeout, :rpc}} end))

      :ok = Sampler.tick(name)

      assert [_ | _] = Store.query(:snapshots, [], ctx.store)
      assert [] == Store.query(:memory, [], ctx.store)
    end

    test "with snapshots switched off, no memory is read or stored", ctx do
      :ok = Settings.put_snapshots_enabled(false)
      name = start_sampler(ctx, connected(memory: fn _ -> flunk("should not read memory") end))

      :ok = Sampler.tick(name)

      assert [] == Store.query(:memory, [], ctx.store)
    end

    test "with snapshots switched off, logs are still stored and no snapshot is", ctx do
      :ok = Settings.put_snapshots_enabled(false)

      {:ok, logs} = Agent.start_link(fn -> [log(1)] end)
      name = start_sampler(ctx, connected(logs: fn -> Agent.get(logs, & &1) end))

      :ok = Sampler.tick(name)

      assert [] == Store.query(:snapshots, [], ctx.store)
      assert [1] == Enum.map(Store.query(:logs, [], ctx.store), & &1.data["id"])
    end

    test "with snapshots switched off, closed episodes are dropped, not stored", ctx do
      :ok = Settings.put_snapshots_enabled(false)
      {:ok, procs} = Agent.start_link(fn -> peers(true) end)

      monitor_source = %{
        status: fn -> %{status: :connected, node: :app@host} end,
        processes: fn -> {:ok, Agent.get(procs, & &1)} end
      }

      name = start_sampler(ctx, connected(), monitor_source)

      for _ <- 1..9, do: :ok = AnomalyMonitor.tick(@monitor)
      Agent.update(procs, fn _ -> peers(false) end)
      :ok = AnomalyMonitor.tick(@monitor)

      :ok = Sampler.tick(name)

      assert [] == Store.query(:anomalies, [], ctx.store)
      assert [] == AnomalyMonitor.history(@monitor)
    end

    test "nothing is sampled while disconnected", ctx do
      source = %{
        status: fn -> %{status: :disconnected, node: nil} end,
        processes: fn -> flunk("should not read processes") end,
        details: fn _pid, _max -> nil end,
        logs: fn -> [] end
      }

      name = start_sampler(ctx, source)
      :ok = Sampler.tick(name)

      assert [] == Store.query(:snapshots, [], ctx.store)
    end

    test "episodes the monitor closed are stored as anomaly rows on the next sample", ctx do
      {:ok, procs} = Agent.start_link(fn -> peers(true) end)

      monitor_source = %{
        status: fn -> %{status: :connected, node: :app@host} end,
        processes: fn -> {:ok, Agent.get(procs, & &1)} end
      }

      name = start_sampler(ctx, connected(), monitor_source)

      for _ <- 1..9, do: :ok = AnomalyMonitor.tick(@monitor)
      Agent.update(procs, fn _ -> peers(false) end)
      :ok = AnomalyMonitor.tick(@monitor)

      :ok = Sampler.tick(name)

      assert [row] = Store.query(:anomalies, [], ctx.store)

      assert %{node: @node, pid: "#PID<0.10.0>", measure: "memory"} = row
      assert %{"kind" => "peer_outlier", "samples" => 1} = row.data

      assert [] == AnomalyMonitor.history(@monitor)
    end

    test "a real peer node is sampled into snapshot rows", ctx do
      {peer, node} = Fixture.start_peer()
      {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie())

      on_exit(fn ->
        Target.disconnect()
        Fixture.stop_peer(peer)
      end)

      name = start_sampler(ctx, %{})
      :ok = Sampler.tick(name)

      rows = Store.query(:snapshots, [], ctx.store)
      assert rows != []
      assert Enum.all?(rows, &(&1.node == Atom.to_string(node)))
      assert Enum.any?(rows, &(&1.reason == "memory"))
    end
  end

  defp start_sampler(ctx, source, monitor_source \\ %{}) do
    start_supervised!(
      {AnomalyMonitor, name: @monitor, interval: :infinity, source: monitor_source}
    )

    name = :"sampler_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Sampler,
       name: name, store: ctx.store, monitor: @monitor, interval: :infinity, source: source}
    )

    name
  end

  defp connected(overrides \\ []) do
    Map.merge(
      %{
        status: fn -> %{status: :connected, node: :app@host} end,
        processes: fn -> {:ok, [proc(1, 100)]} end,
        details: fn _pid, _max -> {:ok, %{}} end,
        memory: fn _node -> {:ok, memory_snapshot(), []} end,
        logs: fn -> [] end
      },
      Map.new(overrides)
    )
  end

  defp memory_snapshot do
    %{memory: %{total: 1_000, processes: 600}, atom_count: 10, ets_count: 3}
  end

  defp ets_table(i) do
    %{
      name: :"table_#{i}",
      named: true,
      type: :set,
      size: i,
      memory: i * 100,
      owner_name: :owner
    }
  end

  defp log(id) do
    %{
      id: id,
      at: DateTime.from_unix!(1_800_000_000 + id),
      level: :error,
      pid: nil,
      where: nil,
      message: "message #{id}",
      fields: [],
      json_line?: false,
      meta: [],
      raw: "message #{id}"
    }
  end
end
