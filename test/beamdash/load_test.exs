defmodule Beamdash.LoadTest do
  # Load Charts: Observer's scheduler utilization, memory and IO charts.
  use ExUnit.Case, async: false

  alias Beamdash.{Load, Target}
  alias Beamdash.Test.Fixture
  alias BeamdashWeb.LoadLive

  defp sample(at, sched, io_in \\ 0, mem \\ 1000) do
    %{
      at_ms: at,
      scheduler_wall_time: sched,
      schedulers: 2,
      dirty_cpu_schedulers: 1,
      io_input: io_in,
      io_output: 0,
      memory: %{
        total: mem,
        processes: div(mem, 2),
        atom: 1,
        binary: 2,
        code: 3,
        ets: 4,
        system: 9
      }
    }
  end

  test "utilization per scheduler is Δactive / Δtotal, as Observer computes it" do
    a = [{1, 0, 0}, {2, 0, 0}, {3, 0, 0}]
    b = [{2, 500, 1000}, {1, 250, 1000}, {3, 0, 1000}]
    assert Load.utilization(a, b) == [25.0, 50.0, 0.0]
    assert Load.utilization(:undefined, b) == nil
    assert Load.utilization(a, Enum.take(b, 2)) == :changed
  end

  test "points carry utilization, memory and IO per second, over the last 60 s" do
    s =
      Load.new()
      |> Load.add(sample(0, [{1, 0, 0}, {2, 0, 0}, {3, 0, 0}]))
      |> Load.add(sample(500, [{1, 100, 500}, {2, 0, 500}, {3, 500, 500}], 2_000, 3000))

    assert [p] = s.points
    assert p.util == [20.0, 0.0, 100.0]
    assert p.io == {4_000.0, 0.0}
    assert p.memory == %{total: 3000, processes: 1500, atom: 1, binary: 2, code: 3, ets: 4}
    assert s.dirty == 1

    s =
      Enum.reduce(1..130, s, fn i, s ->
        Load.add(s, sample(500 + i * 500, [{1, i, i * 10}, {2, 0, i * 10}, {3, 0, i * 10}]))
      end)

    assert List.last(s.points).at_ms - hd(s.points).at_ms <= Load.window_ms()
    assert length(s.points) == 121
  end

  test "the page draws Observer's three charts" do
    s =
      Load.new()
      |> Load.add(sample(0, [{1, 0, 0}, {2, 0, 0}, {3, 0, 0}]))
      |> Load.add(sample(500, [{1, 100, 500}, {2, 0, 500}, {3, 500, 500}], 2_000, 3_000_000))
      |> Load.add(sample(1000, [{1, 200, 1000}, {2, 0, 1000}, {3, 600, 1000}], 4_000, 3_100_000))

    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = LoadLive.mount(%{}, %{}, socket)

    html =
      socket.assigns
      |> Map.merge(%{syntax: :erlang, status: :connected, load: s})
      |> LoadLive.render()
      |> Phoenix.LiveViewTest.rendered_to_string()

    assert html =~ "Scheduler Utilization (%)"
    assert html =~ "Memory Usage"
    assert html =~ "IO Usage"
    # two normal schedulers and one dirty CPU scheduler, dotted
    assert length(Regex.scan(~r/<polyline/, html)) == 3 + 6 + 2
    assert html =~ ~s(stroke-dasharray="3 3")
    # the legend: scheduler groups with their averages, an item per line
    assert html =~ ~r/Schedulers\s*<span class="muted">· 2 · now avg 10%/
    assert html =~ ~r/Dirty CPU schedulers \(dotted\)\s*<span class="muted">· 1 · now avg 20%/
    assert html =~ ~s(title="Dirty CPU scheduler 1")
    assert length(Regex.scan(~r/class="load-item"/, html)) == 3 + 6 + 2
    # hovering an item highlights its line
    assert html =~
             ~s|#chart-sched:has(.load-item[data-s="2"]:is(:hover, :focus-visible)) polyline:not([data-s="2"])|

    assert html =~ ~s(data-s="2")
    assert html =~ "3.9 KB/s"
    assert html =~ ~s(href="/load")
    assert html =~ "<span>5.0 MB</span>"
    assert LoadLive.nice_bytes(3_100_000) == 5 * 1_048_576
    assert LoadLive.nice_bytes(1500) == 2048
    assert LoadLive.nice_bytes(30 * 1_048_576) == 50 * 1_048_576
  end

  describe "the sampler on the target" do
    setup do
      {peer, node} = Fixture.start_peer()
      on_exit(fn -> Fixture.stop_peer(peer) end)

      target =
        start_supervised!({Target, name: :"load_target_#{System.unique_integer([:positive])}"})

      {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie(), target)
      %{node: node}
    end

    test "sends samples while its page lives, then turns scheduler_wall_time off", %{node: node} do
      parent = self()

      page =
        spawn(fn ->
          {:ok, sampler} = Load.start(node)
          send(parent, {:sampler, sampler})

          for _ <- 1..2 do
            receive do
              {:beamdash_load, ^sampler, sample} -> send(parent, {:sample, sample})
            end
          end

          receive do: (:quit -> :ok)
        end)

      assert_receive {:sampler, sampler}, 5_000
      assert_receive {:sample, first}, 5_000
      assert_receive {:sample, second}, 5_000
      assert second.at_ms - first.at_ms >= Load.interval_ms() - 50
      assert is_list(second.scheduler_wall_time)
      assert length(second.scheduler_wall_time) >= second.schedulers
      assert second.memory.total > 0

      ref = Process.monitor(sampler)
      send(page, :quit)
      assert_receive {:DOWN, ^ref, :process, ^sampler, _}, 5_000
      assert :erpc.call(node, :erlang, :statistics, [:scheduler_wall_time]) == :undefined
    end
  end
end
