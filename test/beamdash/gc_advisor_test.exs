defmodule Beamdash.GCAdvisorTest do
  use ExUnit.Case, async: false
  alias Beamdash.{GCAdvisor, Settings}
  alias Beamdash.Test.Fixture

  setup do
    previous = Settings.jev_enabled?()
    Settings.put_jev_enabled(true)
    on_exit(fn -> Settings.put_jev_enabled(previous) end)
    Fixture.put_jev_config(api_key: "test-key")
  end

  defp response(choice, p) do
    rest = (1.0 - p) / (map_size(GCAdvisor.choices()) - 1)

    %{
      "model" => "jev-test",
      "answers" => %{
        "next_step" => %{
          "type" => "choice",
          "choice" => choice,
          "confidence" => 0.9,
          "probabilities" =>
            Map.new(GCAdvisor.choices(), fn {k, _} -> {k, if(k == choice, do: p, else: rest)} end)
        }
      }
    }
  end

  defp samples(detail, n) do
    for i <- 0..(n - 1), do: Map.put(GCAdvisor.sample(detail), :offset_ms, i * 1000)
  end

  defp private_detail do
    Fixture.gc_detail()
    |> Map.merge(%{
      registered_name: :secret_process,
      current_stacktrace: [:secret_stack],
      application_state: "private data",
      mailbox: %{length: 3, messages: ["private message"]}
    })
    |> put_in([:memory, :secret], "hidden")
  end

  test "state holds derived facts and excludes identities, stacks, state and messages" do
    d = private_detail()

    data =
      GCAdvisor.evidence(
        d,
        samples(d, 20),
        [%{kind: :major, duration_us: 5, before: 200, after: 100}],
        2000,
        1,
        %{before: 2000, after: 1000}
      )

    assert data.observed_samples == 20
    assert data.observed_window_s == 19
    assert data.mailbox.queued_now == 3
    assert data.heap.memory_growth_bytes_per_s == 0.0
    assert data.gc_trace.full_sweeps == 1
    assert data.gc_trace.collections_per_s == 0.5
    assert data.gc_trace.forced_by_user == 1
    assert data.last_forced_gc.freed_pct == 50.0
    encoded = Jason.encode!(data)
    refute encoded =~ "secret"
    refute encoded =~ "hidden"
    refute encoded =~ "private"
    refute encoded =~ "pid"
  end

  test "asks only with enough history" do
    d = Fixture.gc_detail()
    assert {:collecting, 4, 15} = GCAdvisor.readiness(samples(d, 5))
    assert {:collecting, _, _} = GCAdvisor.readiness([])
    assert {:ready, 19} = GCAdvisor.readiness(samples(d, 20))
  end

  test "the GC panel shows the answer, its ranking and what it was based on" do
    view = BeamdashWeb.GCLive
    {:ok, socket} = view.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
    d = Fixture.gc_detail()
    evidence = GCAdvisor.evidence(d, samples(d, 20), [], 0, 0, nil)

    {:ok, advice} =
      GCAdvisor.analyze(evidence,
        api_key: "k",
        request: fn _, _, _, _ ->
          {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], Jason.encode!(response("inspect_binaries", 1))}}
        end
      )

    request = {:gc_advisor, make_ref()}

    socket =
      Phoenix.Component.assign(socket,
        advisor_request: request,
        advisor_evidence: evidence,
        syntax: :erlang,
        status: :connected,
        selected: self(),
        detail: d,
        samples: samples(d, 20)
      )

    {:noreply, socket} = view.handle_async(request, {:ok, {:ok, advice}}, socket)
    html = view.render(socket.assigns) |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "Inspect retained binaries"
    assert html =~ "100%"
    assert html =~ "Based on 20 samples over 19 s"
    assert html =~ "What is sent to TypeSafe"
    assert html =~ ~s(id="gc-force-collect")
  end

  test "the Analyze button waits for history" do
    view = BeamdashWeb.GCLive
    {:ok, socket} = view.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
    d = Fixture.gc_detail()

    socket =
      Phoenix.Component.assign(socket,
        syntax: :erlang,
        status: :connected,
        selected: self(),
        detail: d,
        jev_enabled: true,
        samples: samples(d, 4)
      )

    previous = Application.get_env(:beamdash, Beamdash.Jev, [])
    on_exit(fn -> Application.put_env(:beamdash, Beamdash.Jev, previous) end)
    Application.put_env(:beamdash, Beamdash.Jev, Keyword.put(previous, :api_key, "k"))

    html = view.render(socket.assigns) |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "collecting history · 3 of 15 s"
    assert html =~ ~s(phx-click="analyze_gc" disabled)

    {:noreply, socket} = view.handle_event("analyze_gc", %{}, socket)
    assert socket.assigns.advisor_request == nil
    assert socket.assigns.advisor_error =~ "still being collected"
  end

  test "async results from a previously selected process are discarded" do
    view = BeamdashWeb.GCLive
    {:ok, socket} = view.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
    active = {:gc_advisor, make_ref()}
    old = {:gc_advisor, make_ref()}
    socket = Phoenix.Component.assign(socket, advisor_request: active)
    advice = %{title: "x"}
    assert {:noreply, unchanged} = view.handle_async(old, {:ok, {:ok, advice}}, socket)
    assert unchanged.assigns.advisor == nil
    assert unchanged.assigns.advisor_request == active
    assert {:noreply, finished} = view.handle_async(active, {:ok, {:ok, advice}}, socket)
    assert finished.assigns.advisor == advice
    assert finished.assigns.advisor_request == nil
    {:noreply, failed} = view.handle_async(active, {:ok, {:error, "Rate limited"}}, socket)
    assert failed.assigns.advisor_error == "Rate limited"
  end
end
