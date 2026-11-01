defmodule Beamdash.MemoryPanelTest do
  use ExUnit.Case, async: true

  alias BeamdashWeb.MemoryLive

  test "inspection appears in a resizable side panel and can be closed" do
    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = MemoryLive.mount(%{}, %{}, socket)

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

    inspect = %{
      pid: self(),
      name: nil,
      memory: 100,
      message_queue_len: 0,
      stack: [],
      status: :not_requested
    }

    socket =
      Phoenix.Component.assign(socket,
        syntax: :erlang,
        jev_enabled: false,
        status: :connected,
        snap: snap,
        tab: :binary,
        inspect: inspect
      )

    html = socket.assigns |> MemoryLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ ~s(class="proc-layout memory-layout with-panel")

    assert elem(:binary.match(html, ">Trend<"), 0) <
             elem(:binary.match(html, ~s(class="proc-layout memory-layout with-panel")), 0)

    assert html =~ ~s(id="memory-trend-chart")
    assert html =~ ~s(rowspan="6")
    assert html =~ ~s(aria-label="Hide Processes trend")
    assert html =~ ~s(class="memory-series-processes")
    {:noreply, hidden} = MemoryLive.handle_event("toggle_trend", %{"kind" => "processes"}, socket)

    html_hidden =
      hidden.assigns |> MemoryLive.render() |> Phoenix.LiveViewTest.rendered_to_string()

    assert html_hidden =~ ~s(aria-label="Show Processes trend")
    refute html_hidden =~ ~s(class="memory-series-processes")
    assert html_hidden =~ ~s(class="memory-series-binary")

    {:noreply, restored} =
      MemoryLive.handle_event("toggle_trend", %{"kind" => "processes"}, hidden)

    assert MapSet.member?(restored.assigns.visible_trends, :processes)

    {:noreply, unchanged} =
      MemoryLive.handle_event("toggle_trend", %{"kind" => "invalid"}, restored)

    assert unchanged.assigns.visible_trends == restored.assigns.visible_trends

    none =
      Enum.reduce(~w(processes binary ets code atom other), restored, fn kind, current ->
        {:noreply, current} = MemoryLive.handle_event("toggle_trend", %{"kind" => kind}, current)
        current
      end)

    assert none.assigns |> MemoryLive.render() |> Phoenix.LiveViewTest.rendered_to_string() =~
             "Select a memory kind to show its trend."

    assert html =~ "Last 5 min"

    {:noreply, ten_minutes} =
      MemoryLive.handle_event("zoom_trend", %{"direction" => "out"}, socket)

    assert ten_minutes.assigns.trend_window == 600

    {:noreply, ten_minutes} =
      MemoryLive.handle_event("zoom_trend", %{"direction" => "out"}, ten_minutes)

    assert ten_minutes.assigns.trend_window == 600

    ten_html =
      ten_minutes.assigns |> MemoryLive.render() |> Phoenix.LiveViewTest.rendered_to_string()

    assert ten_html =~ "Last 10 min"
    assert ten_html =~ "−10 min"
    samples = [%{at: 0, memory: snap.memory}, %{at: 600_000, memory: snap.memory}]
    ten_minutes = Phoenix.Component.assign(ten_minutes, trend_history: samples)

    ten_html =
      ten_minutes.assigns |> MemoryLive.render() |> Phoenix.LiveViewTest.rendered_to_string()

    assert ten_html =~ ~r/points="0\.0,[0-9.]+ 600\.0,[0-9.]+"/

    history = [
      %{at: 0, memory: Map.put(snap.memory, :processes, 90)},
      %{at: 180_000, memory: Map.put(snap.memory, :processes, 50)},
      %{at: 300_000, memory: snap.memory}
    ]

    zoom_socket = Phoenix.Component.assign(hidden, trend_history: history)

    {:noreply, zoom_socket} =
      MemoryLive.handle_event("zoom_trend", %{"direction" => "in"}, zoom_socket)

    assert zoom_socket.assigns.trend_window == 120
    assert zoom_socket.assigns.visible_trends == hidden.assigns.visible_trends

    zoom_html =
      zoom_socket.assigns |> MemoryLive.render() |> Phoenix.LiveViewTest.rendered_to_string()

    assert zoom_html =~ "Last 2 min"
    assert zoom_html =~ "−2 min"
    assert zoom_html =~ ~r/points="0\.0,[0-9.]+ 600\.0,[0-9.]+"/

    {:noreply, zoom_socket} =
      MemoryLive.handle_event("zoom_trend", %{"direction" => "in"}, zoom_socket)

    {:noreply, zoom_socket} =
      MemoryLive.handle_event("zoom_trend", %{"direction" => "in"}, zoom_socket)

    {:noreply, zoom_socket} =
      MemoryLive.handle_event("zoom_trend", %{"direction" => "in"}, zoom_socket)

    assert zoom_socket.assigns.trend_window == 30

    {:noreply, zoom_socket} =
      MemoryLive.handle_event("zoom_trend", %{"direction" => "out"}, zoom_socket)

    assert zoom_socket.assigns.trend_window == 60

    small = %{snap.memory | processes: 1_000, binary: 10}
    large = %{snap.memory | processes: 1_100, binary: 20}

    scaled =
      Phoenix.Component.assign(socket,
        trend_history: [%{at: 0, memory: small}, %{at: 300_000, memory: large}],
        visible_trends: MapSet.new([:processes, :binary])
      )

    before = scaled.assigns |> MemoryLive.render() |> Phoenix.LiveViewTest.rendered_to_string()

    [_, before_first, before_last] =
      Regex.run(
        ~r/class="memory-series-binary".*?points="0\.0,([0-9.]+) 600\.0,([0-9.]+)"/s,
        before
      )

    {:noreply, scaled} = MemoryLive.handle_event("toggle_trend", %{"kind" => "processes"}, scaled)

    after_html =
      scaled.assigns |> MemoryLive.render() |> Phoenix.LiveViewTest.rendered_to_string()

    [_, after_first, after_last] =
      Regex.run(
        ~r/class="memory-series-binary".*?points="0\.0,([0-9.]+) 600\.0,([0-9.]+)"/s,
        after_html
      )

    assert String.to_float(after_first) - String.to_float(after_last) >
             String.to_float(before_first) - String.to_float(before_last)

    assert after_html =~ "automatically scaled byte range"
    {:noreply, scaled} = MemoryLive.handle_event("toggle_trend", %{"kind" => "processes"}, scaled)
    assert scaled.assigns.visible_trends == MapSet.new([:processes, :binary])

    assert html =~ ~s(id="memory-process-details")
    assert html =~ ~s(phx-hook="Resizer")
    assert html =~ ~s(phx-click="get_status")
    {:noreply, socket} = MemoryLive.handle_event("close_inspect", %{}, socket)
    html = socket.assigns |> MemoryLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    refute html =~ ~s(id="memory-process-details")
  end
end
