defmodule Exberly.JevFeaturesTest do
  use ExUnit.Case, async: false

  alias Exberly.{AskAdvisor, MemoryAdvisor, SeqAdvisor, Settings, TriageAdvisor}
  alias Exberly.Jev.{MoreScenarios, Scenarios}

  setup do
    previous = Settings.jev_enabled?()
    Settings.put_jev_enabled(true)
    config = Application.get_env(:exberly, Exberly.Jev, [])
    Application.put_env(:exberly, Exberly.Jev, Keyword.put(config, :api_key, "test-key"))

    on_exit(fn ->
      Settings.put_jev_enabled(previous)
      Application.put_env(:exberly, Exberly.Jev, config)
    end)

    :ok
  end

  # A Jev stand-in: answers every question in the request. `pick` gets the
  # question id and its option keys and returns {choice, probability}.
  defp jev(pick, test_pid \\ nil) do
    fn :post, {_url, _headers, _type, body}, _opts, _http ->
      payload = Jason.decode!(body)
      if test_pid, do: send(test_pid, {:payload, payload})

      answers =
        Map.new(payload["questions"], fn {id, q} ->
          keys = Map.keys(q["criteria"])
          {choice, p} = pick.(id, keys)
          rest = (1.0 - p) / (length(keys) - 1)

          {id,
           %{
             "type" => "choice",
             "choice" => choice,
             "confidence" => p,
             "probabilities" => Map.new(keys, &{&1, if(&1 == choice, do: p, else: rest)})
           }}
        end)

      {:ok,
       {{~c"HTTP/1.1", 200, ~c"OK"}, [],
        Jason.encode!(%{"model" => "jev-test", "answers" => answers})}}
    end
  end

  defp always(choice, p \\ 0.9), do: jev(fn _id, _keys -> {choice, p} end)

  describe "memory health" do
    test "derived facts per kind of memory, limits and allocators; nothing identifying" do
      [binary | _] = MoreScenarios.memory()
      e = binary.evidence
      assert e.observed_window_s == 30
      assert e.kinds.binary.change_over_window_pct > 100
      assert e.kinds.processes.change_over_window_pct == 0.0
      assert e.limits.atoms_used_pct < 5
      assert e.allocators.used_share_of_allocated_pct > 80
      refute Jason.encode!(e) =~ "pid"
    end

    test "waits for history, then answers with the view to open" do
      assert {:collecting, 4, 15} =
               MemoryAdvisor.readiness(for s <- 0..2, do: %{at: s * 2000, memory: %{}})

      [binary | _] = MoreScenarios.memory()
      assert {:ok, advice} = MemoryAdvisor.analyze(binary.evidence, request: always("binary"))
      assert advice.title == "Binaries"
      assert advice.view == :binary
      assert {:ok, a} = MemoryAdvisor.analyze(binary.evidence, request: always("atoms"))
      assert a.view == nil
    end
  end

  describe "seq trace pattern" do
    test "shape of the flow: kinds, latency, unanswered calls, fan-out without replies" do
      by = Map.new(MoreScenarios.seq(), &{&1.name, &1.evidence})
      assert by["slow responder"].calls.unanswered == 3
      assert by["slow responder"].calls.reply_latency_ms_mean == 900.0
      assert by["fan-out"].concentration.max_fan_out == 30
      # a server answering 40 callers is not fanning out
      assert by["request storm"].concentration.max_fan_out == 1
      assert by["request storm"].concentration.max_fan_in == 40
      assert by["chatty exchange"].exchange.max_messages_between_one_pair == 40
      assert by["deep chain"].chains.longest == 8
      refute Jason.encode!(by["normal flow"]) =~ "<0."
    end

    test "needs #{SeqAdvisor.min_messages()} messages, counted in messages" do
      assert {:collecting, 0, 10, "messages"} = SeqAdvisor.readiness([])
      [storm | _] = MoreScenarios.seq()
      assert {:ok, a} = SeqAdvisor.analyze(storm.evidence, request: always("request_storm"))
      assert a.title == "Request storm"
      assert a.samples == 80
    end
  end

  describe "triage" do
    test "anonymous ids, one question per tracked process, flags mapped back to pids" do
      t = MoreScenarios.triage()
      {state, questions, ids} = t.evidence
      assert map_size(questions) == 12
      assert Map.keys(state.processes) |> Enum.all?(&String.starts_with?(&1, "p"))
      text = Jason.encode!(state)
      refute text =~ "<0."
      refute text =~ "my_client"

      flag = MapSet.new(t.expect)

      pick = fn id, _keys ->
        if id in flag, do: {"inspect_mailbox", 0.8}, else: {"no_clear_issue", 0.9}
      end

      assert {:ok, result} = TriageAdvisor.analyze(t.evidence, request: jev(pick, self()))
      assert_received {:payload, payload}
      assert map_size(payload["questions"]) == 12
      assert payload["questions"]["p1"]["instructions"]["question"] =~ "`p1`"

      flagged = for {id, pid} <- ids, result.results[pid].flagged, do: id
      assert Enum.sort(flagged) == t.expect
      assert result.count == 12
    end

    test "tracks only candidates, keeps 16 samples, waits for 15 s" do
      procs =
        for i <- 1..40, do: %{pid: :c.pid(0, 600 + i, 0), memory: i * 1000, message_queue_len: 0}

      rates = %{}

      h =
        Enum.reduce(0..20, nil, fn s, h -> TriageAdvisor.track(h, procs, rates, s * 1_000_000) end)

      assert map_size(h.procs) == 10
      assert length(h.samples) == 16
      assert {:ready, 15} = TriageAdvisor.readiness(h)
      assert {:collecting, 0, 15} = TriageAdvisor.readiness(nil)

      own = %{
        pid: :c.pid(0, 699, 0),
        registered_name: :erlyberly_tcollector,
        memory: 10 ** 9,
        message_queue_len: 9
      }

      refute own.pid in TriageAdvisor.candidates([own | procs], rates)
    end
  end

  describe "Ask exberly" do
    test "finds a loaded module named in the question" do
      mods = [:demo_shop, :lists, :"Elixir.MyApp.Repo", :demo]
      assert AskAdvisor.module_in("trace calls to demo_shop please", mods) == :demo_shop
      assert AskAdvisor.module_in("profile MyApp.Repo.get", mods) == :"Elixir.MyApp.Repo"
      assert AskAdvisor.module_in("who leaks binaries?", mods) == nil
      assert AskAdvisor.path("trace", :demo_shop) == "/trace?mod=demo_shop"
      assert AskAdvisor.path("memory_binaries") == "/memory?tab=binary"
      assert AskAdvisor.path("none") == nil
    end

    test "a clear answer navigates; a close one lists options; only the question is sent" do
      assert {:ok, a} =
               AskAdvisor.ask("who is leaking binaries?", nil,
                 request: jev(fn _, _ -> {"memory_binaries", 0.9} end, self())
               )

      assert a.go == "/memory?tab=binary"
      assert_received {:payload, %{"state" => state}}

      assert state == %{
               "question" => "who is leaking binaries?",
               "names_a_loaded_module" => false
             }

      close = fn _, _ -> {"memory_binaries", 0.4} end
      # 0.4 vs 0.6/18 for the rest: still clear; make two options close
      assert {:ok, %{go: "/memory?tab=binary"}} = AskAdvisor.ask("x", nil, request: jev(close))

      tie =
        fn :post, _req, _o, _h ->
          probs =
            Map.new(AskAdvisor.choices(), fn {k, _} ->
              {k,
               case k do
                 "trace" -> 0.45
                 "profile" -> 0.4
                 _ -> 0.15 / (map_size(AskAdvisor.choices()) - 2)
               end}
            end)

          {:ok,
           {{~c"HTTP/1.1", 200, ~c"OK"}, [],
            Jason.encode!(%{
              "model" => "jev-test",
              "answers" => %{
                "next_step" => %{
                  "choice" => "trace",
                  "confidence" => 0.3,
                  "probabilities" => probs
                }
              }
            })}}
        end

      assert {:ok, a} = AskAdvisor.ask("look at demo_shop", :demo_shop, request: tie)
      assert a.go == nil
      assert [%{path: "/trace?mod=demo_shop"}, %{path: "/profile?mod=demo_shop"} | _] = a.options

      assert {:ok, n} = AskAdvisor.ask("weather?", nil, request: always("none"))
      assert n.go == nil
    end

    test "the hook navigates on a clear answer and lists options otherwise" do
      socket =
        %Phoenix.LiveView.Socket{}
        |> Phoenix.Component.assign(:ask, %{query: "q", busy: :ref, options: [], error: nil})

      assert {:halt, s} =
               ExberlyWeb.Ask.handle_info(
                 {:exberly_ask, :ref, {:ok, %{go: "/gc", options: []}}},
                 socket
               )

      assert s.redirected == {:live, :redirect, %{kind: :push, to: "/gc"}}

      options = [%{label: "GC", path: "/gc", probability: 0.5, key: "gc"}]

      assert {:halt, s} =
               ExberlyWeb.Ask.handle_info(
                 {:exberly_ask, :ref, {:ok, %{go: nil, options: options}}},
                 socket
               )

      assert s.assigns.ask.options == options
      assert s.assigns.ask.busy == nil

      html =
        %{
          active: :gc,
          syntax: :erlang,
          conn: nil,
          ask: s.assigns.ask,
          ask_on: true
        }
        |> ExberlyWeb.Layouts.header()
        |> Phoenix.LiveViewTest.rendered_to_string()

      assert html =~ ~s(id="ask-form")
      assert html =~ "Jev suggests"
      assert html =~ ~s(href="/gc")

      # an answer to an earlier question is ignored
      assert {:halt, ^socket} =
               ExberlyWeb.Ask.handle_info({:exberly_ask, :old, {:ok, %{go: "/x"}}}, socket)
    end
  end

  test "every scenario builds, and its expected answers are real options" do
    sets = %{
      process: Exberly.ProcessAdvisor.choices(),
      gc: Exberly.GCAdvisor.choices(),
      memory: MemoryAdvisor.choices(),
      seq: SeqAdvisor.choices(),
      route: AskAdvisor.choices()
    }

    for s <- Scenarios.all() ++ MoreScenarios.all(), s.advisor != :triage do
      assert Enum.all?(s.expect, &Map.has_key?(sets[s.advisor], &1)), "#{s.advisor}/#{s.name}"
    end
  end

  describe "pages" do
    test "Memory tab shows the health check and the view to open" do
      view = ExberlyWeb.MemoryLive
      {:ok, socket} = view.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
      [binary | _] = MoreScenarios.memory()
      {:ok, advice} = MemoryAdvisor.analyze(binary.evidence, request: always("binary"))

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
        atom_count: 1,
        atom_limit: 10,
        process_count: 1,
        process_limit: 10,
        ets_count: 1,
        ets_limit: 10,
        module_count: 1,
        recon: false
      }

      socket =
        Phoenix.Component.assign(socket,
          syntax: :erlang,
          jev_enabled: true,
          status: :connected,
          snap: snap,
          health: %{request: nil, advice: advice, error: nil, evidence: binary.evidence}
        )

      html = view.render(socket.assigns) |> Phoenix.LiveViewTest.rendered_to_string()
      assert html =~ "Jev: node memory health"
      assert html =~ "Look for a leak in Binaries"
      assert html =~ ~s(phx-value-tab="binary")

      {:noreply, s} = view.handle_params(%{"tab" => "ets", "check" => "1"}, "", socket)
      assert s.assigns.tab == :ets
      assert s.assigns.health_auto
    end

    test "Processes tab: triage bar, flags and links with sort and filter" do
      view = ExberlyWeb.HomeLive
      {:ok, socket} = view.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
      pid = :c.pid(0, 777, 0)

      proc = %{
        pid: pid,
        registered_name: :shop,
        initial_call: {:shop, :init, 1},
        current_function: {:gen_server, :loop, 7},
        kind: :gen_server,
        memory: 1000,
        reductions: 10,
        message_queue_len: 5,
        status: :waiting
      }

      triage = %{
        request: nil,
        error: nil,
        evidence: %{},
        only_flagged: false,
        result: %{
          results: %{
            pid => %{
              flagged: true,
              choice: "inspect_mailbox",
              label: "Investigate message backlog",
              worth: 0.8,
              alternative: nil
            }
          },
          model: "jev-test",
          at: DateTime.utc_now(),
          count: 1,
          window_s: 30
        }
      }

      socket =
        Phoenix.Component.assign(socket,
          syntax: :erlang,
          jev_enabled: true,
          status: :connected,
          procs: [proc],
          triage: triage
        )

      html = view.render(socket.assigns) |> Phoenix.LiveViewTest.rendered_to_string()
      assert html =~ "1</strong> of 1 worth a look"
      assert html =~ "⚑ Investigate message backlog"

      {:noreply, s} =
        view.handle_params(%{"sort" => "mq", "q" => "gen_server", "triage" => "1"}, "", socket)

      assert s.assigns.sort_by == :message_queue_len
      assert s.assigns.filter == "gen_server"
      assert s.assigns.triage_auto
    end

    test "Seq trace page shows the pattern check with its basis" do
      view = ExberlyWeb.SeqLive
      {:ok, socket} = view.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
      [storm | _] = MoreScenarios.seq()
      {:ok, advice} = SeqAdvisor.analyze(storm.evidence, request: always("request_storm"))

      events =
        for i <- 1..12,
            do: %{
              id: i,
              type: :send,
              from: "<0.1.0>",
              to: "<0.2.0>",
              message: :hi,
              timestamp_us: i,
              serial: {i, i + 1}
            }

      socket =
        Phoenix.Component.assign(socket,
          syntax: :erlang,
          jev_enabled: true,
          events: events,
          pattern: %{request: nil, advice: advice, error: nil, evidence: storm.evidence}
        )

      html = view.render(socket.assigns) |> Phoenix.LiveViewTest.rendered_to_string()
      assert html =~ "Jev: message-flow pattern"
      assert html =~ "Request storm"
      assert html =~ "Based on 80 messages between 41 processes"
    end
  end
end
