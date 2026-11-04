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
    assert html =~ ~s(>Trend<)
    assert html =~ ~s(class="proc-layout memory-layout with-panel")
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

    leak = Phoenix.Component.assign(socket, page: :leak)
    html = leak.assigns |> MemoryLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ ~s(class="proc-layout memory-layout with-panel")
    assert html =~ ~s(id="memory-process-details")
    assert html =~ ~s(phx-hook="Resizer")
    assert html =~ ~s(phx-click="get_status")
    {:noreply, leak} = MemoryLive.handle_event("close_inspect", %{}, leak)
    html = leak.assigns |> MemoryLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    refute html =~ ~s(id="memory-process-details")
  end

  test "forecast and the leak search each have their own page" do
    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = MemoryLive.mount(%{}, %{}, socket)

    memory = %{
      total: 100,
      processes: 40,
      processes_used: 40,
      system: 60,
      atom: 1,
      atom_used: 1,
      binary: 30,
      code: 10,
      ets: 10
    }

    snap = %{
      memory: memory,
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
        jev_enabled: false,
        status: :connected,
        snap: snap,
        forecast: {:collecting, 5, 60}
      )

    render = fn assigns ->
      assigns |> MemoryLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    end

    loaded = render.(socket.assigns)
    assert loaded =~ ">Trend<"
    assert loaded =~ ~s(class="mem-h2")
    refute loaded =~ ~s(id="forecast-heading")

    {:noreply, forecast} = MemoryLive.handle_event("page", %{"page" => "forecast"}, socket)
    forecast_html = render.(forecast.assigns)
    assert forecast_html =~ ~s(id="forecast-heading")
    assert forecast_html =~ ">Trend<"

    {:noreply, leak} = MemoryLive.handle_event("page", %{"page" => "leak"}, forecast)
    leak_html = render.(leak.assigns)
    assert leak_html =~ ~s(class="mem-h2")
    refute leak_html =~ ~s(id="forecast-heading")
    assert leak_html =~ ">Trend<"
  end

  test "a table's browse opens in the side column, and a tab change closes it" do
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

    browse = %{
      table: :tab,
      label: "tab",
      key: "",
      spec: "",
      rows: 500,
      result: nil,
      examples: nil,
      key_pick: 0,
      spec_pick: 0,
      view: :raw,
      output: %{segments: [], pairs: []}
    }

    showing = fn socket, result, view ->
      socket =
        Phoenix.Component.assign(socket,
          ets_browse: %{socket.assigns.ets_browse | result: result}
        )

      {:noreply, socket} = MemoryLive.handle_event("ets_view", %{"view" => view}, socket)
      socket
    end

    socket =
      Phoenix.Component.assign(socket,
        syntax: :erlang,
        jev_enabled: false,
        status: :connected,
        snap: snap,
        page: :leak,
        tab: :ets,
        ets: [],
        ets_base: %{},
        ets_browse: browse
      )

    html = socket.assigns |> MemoryLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ ~s(class="proc-layout memory-layout with-panel")

    assert html =~
             ~r/<div class="proc-side memory-inspect-side">\s*<aside class="proc-panel memory-inspect ets-browse"/

    assert html =~ ~s(id="ets-browse-resizer")
    assert html =~ ~s(value="select" class="secondary ets-action")
    refute html =~ "First rows"

    table = %{
      id: :tab,
      name: :tab,
      named: true,
      owner: self(),
      owner_name: nil,
      type: :set,
      protection: :public,
      size: 7,
      memory: 2048
    }

    with_table = Phoenix.Component.assign(socket, ets: [table])
    html = with_table.assigns |> MemoryLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "set, public"
    assert html =~ "7 rows"

    long_row = {:long_key, Enum.map(1..60, &{:"key_#{&1}", &1})}
    result = {:ok, %{rows: [long_row], stop: :complete, keypos: 1}}
    shown = showing.(socket, result, "raw")
    html = shown.assigns |> MemoryLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "key_60"
    assert html =~ "long_key"
    assert html =~ ~s(<span class="tok-curly">{</span>)
    assert html =~ ~s(<span class="tok-square">[</span>)
    assert html =~ ~s(<span class="tok-comma">,</span>)
    refute html =~ ~s(class="ets-kv")

    table_shown = showing.(socket, result, "table")

    html = table_shown.assigns |> MemoryLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ ~s(class="ets-kv")
    assert html =~ "<th>Key</th>"
    assert html =~ "<th>Value</th>"

    swapped = showing.(socket, {:ok, %{rows: [{:v, :k}], stop: :complete, keypos: 2}}, "table")
    html = swapped.assigns |> MemoryLive.render() |> Phoenix.LiveViewTest.rendered_to_string()

    assert html =~
             ~r/<td class="ets-rows small">\s*<span[^>]*>k<\/span>\s*<\/td>\s*<td class="ets-rows small">\s*<span[^>]*>v<\/span>/

    single = showing.(socket, {:ok, %{rows: [{:only}], stop: :complete, keypos: 1}}, "table")
    html = single.assigns |> MemoryLive.render() |> Phoenix.LiveViewTest.rendered_to_string()

    assert html =~
             ~r/<td class="ets-rows small">\s*<span[^>]*>only<\/span>\s*<\/td>\s*<td class="ets-rows small">\s*<\/td>/

    quoted = {:ok, %{rows: [{"{x}", 1}], stop: :complete, keypos: 1}}
    quoted_socket = showing.(socket, quoted, "raw")

    html =
      quoted_socket.assigns |> MemoryLive.render() |> Phoenix.LiveViewTest.rendered_to_string()

    assert html =~ "&quot;{x}&quot;"
    refute html =~ ~s(<span class="tok-curly">{</span>x)

    examples =
      {:ok, %{keys: ["42"], specs: [{"[{'$1', '_'}]", "Whole rows with a key above 1."}]}}

    with_examples = Phoenix.Component.assign(socket, ets_browse: %{browse | examples: examples})

    html =
      with_examples.assigns |> MemoryLive.render() |> Phoenix.LiveViewTest.rendered_to_string()

    assert html =~ ~s(phx-value-kind="key")
    assert html =~ ~s(phx-value-kind="spec")
    assert html =~ "Whole rows with a key above 1."
    assert html =~ "Key lookup"
    assert html =~ "Sample match specs"

    {:noreply, socket} = MemoryLive.handle_event("tab", %{"tab" => "binary"}, socket)
    assert socket.assigns.ets_browse == nil
  end
end
