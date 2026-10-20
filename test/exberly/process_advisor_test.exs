defmodule Exberly.ProcessAdvisorTest do
  use ExUnit.Case, async: false
  alias Exberly.{ProcessAdvisor, ProcessStats, Settings, Target}
  alias Exberly.Test.Fixture

  setup do
    enabled = Settings.jev_enabled?()
    Settings.put_jev_enabled(true)
    config = Application.get_env(:exberly, Exberly.Jev, [])
    Application.put_env(:exberly, Exberly.Jev, Keyword.put(config, :api_key, "test-key"))
    {peer, node} = Fixture.start_peer()
    {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie())
    :ok = Fixture.load(node)
    {:ok, pid} = :erpc.call(node, :exberly_fixture, :start, [])
    {:ok, detail} = Target.process_details(pid)

    on_exit(fn ->
      Target.disconnect()
      Fixture.stop_peer(peer)
      Settings.put_jev_enabled(enabled)
      Application.put_env(:exberly, Exberly.Jev, config)
    end)

    %{detail: detail, pid: pid}
  end

  defp analyze(evidence, confidence \\ 0.9) do
    request = fn _, {_, _, _, body}, _, _ ->
      payload = Jason.decode!(body)
      assert payload["state"] == Jason.decode!(Jason.encode!(evidence))
      criteria = payload["questions"]["next_step"]["criteria"]
      assert Map.has_key?(criteria, "profile_cpu")
      # "not enough evidence" is decided locally, never offered to the model
      refute Map.has_key?(criteria, "insufficient_evidence")
      assert criteria["profile_cpu"]["not_for"] =~ "idle"

      result = %{
        "model" => "jev-test",
        "answers" => %{
          "next_step" => %{
            "type" => "choice",
            "choice" => "profile_cpu",
            "confidence" => confidence,
            "probabilities" =>
              Map.new(criteria, fn {key, _} -> {key, if(key == "profile_cpu", do: 1, else: 0)} end)
          }
        }
      }

      {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], Jason.encode!(result)}}
    end

    ProcessAdvisor.analyze(evidence, api_key: "test-key", request: request)
  end

  test "payload retains numeric trends while excluding process identities and messages", %{
    detail: detail
  } do
    private =
      Map.merge(detail, %{
        registered_name: :secret_name,
        current_stacktrace: ["secret_stack"],
        mailbox: %{length: 2, messages: ["secret_message"]},
        state: "secret_state"
      })

    history = ProcessStats.push([], detail)
    evidence = ProcessAdvisor.evidence(private, history)
    assert evidence.mailbox.queued_now == 2
    assert evidence.process.status == :waiting
    assert evidence.process.waiting_in == :otp_receive_loop
    assert evidence.observed_samples == 1
    assert hd(evidence.raw_series).at_s == 0.0
    text = Jason.encode!(evidence)
    refute text =~ "secret"
    refute text =~ "exberly_fixture"
    refute text =~ "pid"
    assert {:ok, advice} = analyze(evidence)
    assert advice.title == "Profile CPU work"
    assert length(advice.ranking) == 8
    # low confidence keeps the model's answer
    assert {:ok, low} = analyze(evidence, 0.3)
    assert low.title == "Profile CPU work"
  end

  test "process selection renders analysis; switching, closing and disabling clear advice", %{
    detail: detail,
    pid: pid
  } do
    view = ExberlyWeb.HomeLive
    {:ok, socket} = view.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
    socket = Phoenix.Component.assign(socket, syntax: :erlang)

    {:noreply, socket} =
      view.handle_event("select", %{"pid" => Exberly.Format.pid(pid, :erlang)}, socket)

    {:noreply, socket} = view.handle_info({:detail_tick, pid}, socket)
    assert socket.assigns.details.pid == pid
    evidence = ProcessAdvisor.evidence(detail, socket.assigns.history)
    {:ok, advice} = analyze(evidence)
    request = {:process_advisor, make_ref()}

    socket =
      Phoenix.Component.assign(socket,
        process_advice_request: request,
        process_evidence: evidence
      )

    {:noreply, socket} = view.handle_async(request, {:ok, {:ok, advice}}, socket)
    html = view.render(socket.assigns) |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ ~s(phx-click="analyze_process")
    assert html =~ "Profile CPU work"
    assert html =~ "What is sent to TypeSafe"
    # one sample so far: the button waits for history
    assert html =~ "collecting history"
    {:noreply, closed} = view.handle_event("close_details", %{}, socket)
    assert closed.assigns.process_advice == nil
    assert closed.assigns.process_evidence == nil

    {:noreply, switched} =
      view.handle_event("select", %{"pid" => Exberly.Format.pid(self(), :erlang)}, socket)

    assert switched.assigns.process_advice == nil
    Settings.put_jev_enabled(false)
    disabled = socket |> Phoenix.Component.assign(jev_enabled: false) |> view.jev_changed()
    assert disabled.assigns.process_advice == nil
    assert disabled.assigns.details.pid == pid
    html = view.render(disabled.assigns) |> Phoenix.LiveViewTest.rendered_to_string()
    refute html =~ "Jev"
    refute html =~ ~s(id="jev-process")
    refute html =~ ~s(phx-click="analyze_process")
  end

  test "old asynchronous results and results received after disabling are ignored" do
    view = ExberlyWeb.HomeLive
    {:ok, socket} = view.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
    request = {:process_advisor, make_ref()}
    socket = Phoenix.Component.assign(socket, process_advice_request: request)

    {:noreply, ignored} =
      view.handle_async({:process_advisor, make_ref()}, {:ok, {:ok, %{title: "old"}}}, socket)

    assert ignored.assigns.process_advice == nil
    Settings.put_jev_enabled(false)
    {:noreply, ignored} = view.handle_async(request, {:ok, {:ok, %{title: "old"}}}, socket)
    assert ignored.assigns.process_advice == nil

    assert {:error, message} =
             ProcessAdvisor.analyze(%{},
               api_key: "test-key",
               request: fn _, _, _, _ -> flunk("disabled request") end
             )

    assert message =~ "off"
  end

  test "readiness needs 15 samples over at least 14 s" do
    point = fn s ->
      %{at_us: s * 1_000_000, reductions: 0, reds_per_sec: 0, memory: 1, message_queue_len: 0}
    end

    assert {:collecting, 9, 15} = ProcessAdvisor.readiness(Enum.map(0..9, point))
    assert {:ready, 14} = ProcessAdvisor.readiness(Enum.map(0..14, point))
    assert {:collecting, 0, 15} = ProcessAdvisor.readiness([])
  end

  test "node context ranks the process without identifying it", %{detail: detail, pid: pid} do
    rows =
      [%{pid: pid, memory: 1000, queue: 5, rate: 10, kind: :gen_server}] ++
        for i <- 1..9, do: %{pid: :c.pid(0, 800 + i, 0), memory: 10, queue: 0, rate: 1, kind: nil}

    context = Exberly.Jev.Features.node_context(rows, pid)
    assert context.otp_kind == :gen_server
    assert context.memory_rank_top_pct == 10.0
    assert context.queue_rank_top_pct == 10.0
    evidence = ProcessAdvisor.evidence(detail, ProcessStats.push([], detail), context)
    refute Jason.encode!(evidence) =~ "pid"
  end
end
