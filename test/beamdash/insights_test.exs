defmodule Beamdash.InsightsTest do
  use ExUnit.Case, async: false

  alias Beamdash.{Jev, ProcessAdvisor, Settings}
  alias Beamdash.Insights.{Anomaly, Forecast, Graph, Groups, Model, Series, Training}
  alias Beamdash.Jev.{MoreScenarios, Scenarios}
  alias Beamdash.Test.Fixture

  @mb 1_048_576

  describe "series" do
    test "trend, change point and last-sample z over padded series" do
      {ts, ys, mask} =
        Series.batch([
          for(i <- 0..29, do: {i * 2.0, if(i < 20, do: 1.0, else: 3.0)}),
          for(i <- 0..29, do: {i * 2.0, i * 0.1}),
          for(i <- 0..9, do: {i * 2.0, 5.0})
        ])

      trend = Series.trend(ts, ys, mask)
      assert [_, ramp_slope, 0.0] = Nx.to_flat_list(trend.slope)
      assert_in_delta ramp_slope, 0.05, 1.0e-4
      assert [_, 1.0, 0.0] = trend.r2 |> Nx.to_flat_list() |> Enum.map(&Float.round(&1, 3))

      cp = Series.change_point(ys, mask)
      assert [step_score, _, flat_score] = Nx.to_flat_list(cp.score)
      assert step_score > 50 and flat_score == 0.0
      assert hd(Nx.to_flat_list(cp.index)) == 20

      assert [0.0, _, _, 0.0, outlier] =
               Nx.tensor([1.0, 1.1, 0.9, 1.0, 9.0]) |> Series.robust_z() |> Nx.to_flat_list()

      assert outlier > 10
    end
  end

  describe "anomalies" do
    defp pid(i), do: :c.pid(0, 500 + i, 0)

    defp proc(i, memory, queue, initial_call) do
      %{
        pid: pid(i),
        memory: memory,
        message_queue_len: queue,
        reductions: 0,
        kind: :gen_server,
        initial_call: initial_call,
        registered_name: nil,
        status: :waiting
      }
    end

    defp node_at(s) do
      [
        proc(1, 1_000_000 + s * 200_000, 0, {:cache, :init, 1}),
        proc(2, 300_000, if(s >= 20, do: 500 + s, else: 0), {:sink, :init, 1})
        | for(
            i <- 10..29,
            do: proc(i, if(i == 10, do: 90_000_000, else: 50_000 + i * 100), 0, {:pool, :init, 1})
          )
      ]
    end

    test "a leak, a backlog and an outlier among its peers; quiet processes are left out" do
      history =
        Enum.reduce(0..29, nil, fn s, h -> Anomaly.track(h, node_at(s), %{}, s * 2_000_000) end)

      assert {:ready, 58} = Anomaly.readiness(history)
      findings = Anomaly.detect(history, node_at(29), %{})

      assert [
               %{pid: p2, measure: :queue, kind: :shift, since_s: 18},
               %{pid: p10, measure: :memory, kind: :peer_outlier},
               %{pid: p1, measure: :memory, kind: :rising}
             ] = findings

      assert {p1, p2, p10} == {pid(1), pid(2), pid(10)}
    end

    test "processes started as a plain fun are not each other's peers" do
      spawned =
        for i <- 40..60,
            do: %{
              proc(i, if(i == 40, do: 90_000_000, else: 50_000), 0, {:erlang, :apply, 2})
              | kind: nil
            }

      assert Anomaly.detect(nil, spawned, %{}) == []
    end

    test "too few samples is not ready and finds nothing over time" do
      history = Anomaly.track(nil, node_at(0), %{}, 0)
      assert {:collecting, 1, _} = Anomaly.readiness(history)
      assert Enum.all?(Anomaly.detect(history, node_at(0), %{}), &(&1.kind == :peer_outlier))
    end
  end

  test "groups: k-means separates busy queued workers from idle servers" do
    idle =
      for i <- 1..30,
          do: %{
            pid: :c.pid(0, 600 + i, 0),
            memory: 20_000 + i,
            message_queue_len: 0,
            status: :waiting,
            kind: :gen_server,
            initial_call: {:idle, :init, 1}
          }

    busy =
      for i <- 1..10,
          do: %{
            pid: :c.pid(0, 700 + i, 0),
            memory: 50_000_000 + i,
            message_queue_len: 5_000,
            status: :running,
            kind: nil,
            initial_call: {:worker, :loop, 0}
          }

    rates = Map.new(busy, &{&1.pid, 900_000})

    assert {:ok, [big, small]} = Groups.group(idle ++ busy, rates, 2)
    assert %{size: 30, kind: {:gen_server, 100}, initial_call: {{:idle, :init, 1}, 100}} = big
    assert %{size: 10, rate: 900_000, running_pct: 100.0} = small
    assert length(small.members) == 5
    assert {:error, _} = Groups.group(Enum.take(idle, 1), %{}, 3)
  end

  test "forecast: a line through each measure, and when a count reaches its limit" do
    history =
      for s <- 0..40 do
        %{
          at: s * 2000,
          memory: %{
            total: 500 * @mb + s * @mb,
            processes: 200 * @mb,
            binary: 50 * @mb + s * @mb,
            ets: 20 * @mb,
            atom: 2 * @mb,
            code: 40 * @mb
          },
          counts: %{atom_count: 900_000 + s * 500, process_count: 2000, ets_count: 100}
        }
      end

    snap = %{atom_limit: 1_048_576, process_limit: 262_144, ets_limit: 8192}
    assert {:ok, forecasts} = Forecast.forecast(history, snap)
    by_key = Map.new(forecasts, &{&1.key, &1})

    assert %{growing: true, r2: 1.0} = by_key.binary
    assert %{growing: false} = by_key.ets
    # 920,000 atoms, 250 more a second, limit 1,048,576
    assert_in_delta by_key.atom_count.limit_in_s, 514, 2
    assert by_key.process_count.limit_in_s == nil

    assert {:collecting, _, _} = Forecast.forecast(Enum.take(history, 3), snap)
  end

  test "the Memory tab shows the forecast" do
    history =
      for s <- 0..40 do
        %{
          at: s * 2000,
          memory: %{total: 500 * @mb + s * @mb, processes: 200 * @mb, binary: 50 * @mb + s * @mb},
          counts: %{atom_count: 900_000 + s * 500, process_count: 2000, ets_count: 100}
        }
      end

    snap = %{
      memory: %{
        total: 100,
        processes: 40,
        processes_used: 40,
        system: 60,
        atom: 1,
        atom_used: 1,
        binary: 30,
        code: 10,
        ets: 10
      },
      alloc: nil,
      atom_count: 920_000,
      atom_limit: 1_048_576,
      process_count: 2000,
      process_limit: 262_144,
      ets_count: 100,
      ets_limit: 8192,
      module_count: 1,
      recon: false
    }

    view = BeamdashWeb.MemoryLive
    {:ok, socket} = view.mount(%{}, %{}, %Phoenix.LiveView.Socket{})

    socket =
      Phoenix.Component.assign(socket,
        syntax: :erlang,
        jev_enabled: false,
        status: :connected,
        snap: snap,
        forecast: Forecast.forecast(history, snap)
      )

    html = view.render(socket.assigns) |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "Forecast"
    # 1 MB every 2 s
    assert html =~ ~r/Binaries.*\+30.0 MB/s
    assert html =~ "reached in about 9 min"
    assert html =~ "262,144 (not approaching)"
  end

  test "message graph: reciprocity and the most central process" do
    fan_out = for i <- 1..10, do: %{from: :hub, to: i}
    assert %{reciprocity_pct: 0.0, processes: 11} = Graph.metrics(fan_out)

    chatty =
      for i <- 1..10, do: if(rem(i, 2) == 0, do: %{from: :a, to: :b}, else: %{from: :b, to: :a})

    assert %{reciprocity_pct: 100.0} = Graph.metrics(chatty)

    calls = Enum.flat_map(1..6, &[%{from: &1, to: :server}, %{from: :server, to: &1}])
    assert %{hubs: [{:server, share} | _]} = Graph.metrics(calls)
    assert share > 40
    assert Graph.metrics([]) == nil
  end

  test "the seq advisor sends the graph's shape, never its processes" do
    [storm | _] = MoreScenarios.seq()
    assert %{reciprocity_pct: 100.0, top_centrality_share_pct: _} = storm.evidence.graph
    refute Map.has_key?(storm.evidence.graph, :hubs)
  end

  describe "model" do
    test "a state becomes numbers, missing flags and one-hot categories" do
      vocab = Model.vocabulary([%{a: %{b: 10, c: :x}, d: nil}, %{a: %{b: nil, c: :y}, d: 3}])
      assert vocab == %{numeric: ["a.b", "d"], categorical: ["a.c=x", "a.c=y"]}

      assert [b, +0.0, +0.0, 1.0, 0.0, 1.0] =
               Model.vector(%{a: %{b: 10, c: :y}, e: [1, 2]}, vocab)

      assert_in_delta b, :math.log(11), 1.0e-9
    end

    test "generation is reproducible" do
      assert Training.generate(:process, 2, 5) == Training.generate(:process, 2, 5)
    end

    test "the shipped model answers every fixed scenario it can, in Jev's format" do
      assert Model.available?()
      Fixture.put_jev_config(enabled: true, nx: true)
      previous = Settings.jev_enabled?()
      Settings.put_jev_enabled(true)
      on_exit(fn -> Settings.put_jev_enabled(previous) end)

      scenarios =
        Scenarios.all() ++ Enum.filter(MoreScenarios.all(), &(&1.advisor in [:memory, :seq]))

      advisors = %{
        process: ProcessAdvisor,
        gc: Beamdash.GCAdvisor,
        memory: Beamdash.MemoryAdvisor,
        seq: Beamdash.SeqAdvisor
      }

      for s <- scenarios do
        assert {:ok, a} = advisors[s.advisor].analyze(s.evidence, backend: :nx)
        assert a.choice in s.expect, "#{s.advisor}/#{s.name}: #{a.choice}"
        assert a.model == Model.name()
      end

      triage = MoreScenarios.triage()
      assert {:ok, t} = Beamdash.TriageAdvisor.analyze(triage.evidence, backend: :nx)
      {_state, _questions, ids} = triage.evidence
      flagged = for({id, pid} <- ids, t.results[pid].flagged, do: id) |> Enum.sort()
      assert flagged == triage.expect
    end

    test "Ask is declined, and the backend needs NX_MODEL" do
      Fixture.put_jev_config(enabled: true, nx: true)
      Settings.put_jev_enabled(true)

      assert {:error, msg} = Beamdash.AskAdvisor.ask("who leaks binaries?", nil, backend: :nx)
      assert msg =~ "Ask needs Jev or Kev"

      Fixture.put_jev_config(nx: nil)
      refute Jev.configured?(:nx)
      [s | _] = Scenarios.process()
      assert {:error, msg} = ProcessAdvisor.analyze(s.evidence, backend: :nx)
      assert msg =~ "NX_MODEL"
    end

    test "Nx is a backend like the others: named, chosen and nothing sent" do
      Fixture.put_jev_config(enabled: true, api_key: nil, kev_url: nil, kev_port: nil, nx: true)
      Settings.put_decision_backend(nil)
      on_exit(fn -> Settings.put_decision_backend(nil) end)

      assert Jev.available?()
      assert Jev.backend() == :nx
      assert Jev.name() == "Nx"
      assert Jev.destination() =~ "nothing leaves beamdash"
      assert Jev.endpoint() == "local"
    end
  end

  test "the Insights page renders before connecting and lists findings" do
    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = BeamdashWeb.InsightsLive.mount(%{}, %{}, socket)

    base =
      socket.assigns
      |> Map.merge(%{syntax: :erlang, jev_enabled: false, status: :connected})

    html = base |> BeamdashWeb.InsightsLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "Anomalies"
    assert html =~ "collecting samples"
    assert html =~ "Group processes"

    history =
      Enum.reduce(0..29, nil, fn s, h -> Anomaly.track(h, node_at(s), %{}, s * 2_000_000) end)

    procs = node_at(29)

    html =
      base
      |> Map.merge(%{
        history: history,
        procs: procs,
        by_pid: Map.new(procs, &{&1.pid, &1}),
        findings: Anomaly.detect(history, procs, %{})
      })
      |> BeamdashWeb.InsightsLive.render()
      |> Phoenix.LiveViewTest.rendered_to_string()

    assert html =~ "3 found"
    assert html =~ "jumped from about 0 messages"
    assert html =~ ~s(href="/?pid=%3C0.502.0%3E")
  end
end
