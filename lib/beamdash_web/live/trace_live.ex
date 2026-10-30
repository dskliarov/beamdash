defmodule BeamdashWeb.TraceLive do
  @moduledoc """
  Module/function browser. Click functions to pick them (as on the Profile
  tab: several at once, from any modules), then call trace them (live log
  below) or seq trace them (results on the Seq trace page). With exactly
  one picked, its xref call graph is offered too. With none picked, every
  function of the module can be traced at once.
  """
  use Phoenix.LiveView

  alias Beamdash.{CallGraph, Format, SeqTracer, Target, Tracer}
  alias BeamdashWeb.SourceTabs

  import BeamdashWeb.FunctionList,
    only: [matching_modules: 3, functions_of: 2, needle: 1, matches?: 3, fn_name: 2, highlight: 1]

  # calls a new trace stops after, unless changed (empty: no limit)
  @default_call_limit 30
  @max_log_rows 500

  @impl true
  def mount(_params, _session, socket) do
    %{status: status, node: node} = Target.status()

    socket =
      socket
      |> assign(
        status: status,
        node: node,
        modules: [],
        module_filter: "",
        fn_query: "",
        fn_filter: :all,
        selected: nil,
        # functions picked for tracing: [{mod, fun, arity}], any modules
        picked: [],
        traces: [],
        limits: %{},
        call_limit: Integer.to_string(@default_call_limit),
        seq_traces: [],
        detail: nil,
        graph: nil,
        graph_depth: 4,
        error: nil,
        notice: nil
      )
      |> SourceTabs.init()
      |> stream(:entries, [])

    if connected?(socket) do
      :ok = Target.subscribe()
      :ok = Tracer.subscribe()
      :ok = SeqTracer.subscribe()
      {:ok, if(status == :connected, do: load(socket), else: socket)}
    else
      {:ok, socket}
    end
  end

  defp load(socket) do
    socket =
      assign(socket,
        traces: Tracer.traces(),
        limits: Tracer.limits(),
        seq_traces: SeqTracer.traces()
      )

    socket = stream(socket, :entries, log_rows(socket), reset: true)

    case Tracer.module_functions() do
      {:ok, mods} -> assign(socket, modules: mods, error: nil)
      {:error, reason} -> assign(socket, error: Format.error(reason))
    end
  end

  # ?mod= opens that module (a link from "Ask beamdash")
  @impl true
  def handle_params(%{"mod" => mod}, _uri, socket) do
    case Enum.find(socket.assigns.modules, fn {m, _, _} -> Atom.to_string(m) == mod end) do
      {m, _, _} ->
        {:noreply, socket |> assign(selected: m, module_filter: mod) |> SourceTabs.check(m)}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  ## Events

  @impl true
  # the Source button and the source tabs (see BeamdashWeb.SourceTabs)
  def handle_event(event, params, socket)
      when event in ~w(open_source source_tab close_source),
      do: {:noreply, SourceTabs.event(event, params, socket)}

  def handle_event("filter_modules", %{"q" => q}, socket),
    do: {:noreply, assign(socket, module_filter: q)}

  def handle_event("select_module", %{"mod" => mod}, socket) do
    mod = String.to_existing_atom(mod)
    {:noreply, socket |> assign(selected: mod) |> SourceTabs.check(mod)}
  end

  def handle_event("refresh_modules", _params, socket), do: {:noreply, load(socket)}

  def handle_event("filter_functions", %{"fq" => q}, socket),
    do: {:noreply, assign(socket, fn_query: q)}

  def handle_event("fn_filter", %{"f" => f}, socket)
      when f in ~w(all exported local traced),
      do: {:noreply, assign(socket, fn_filter: String.to_existing_atom(f))}

  # Enter in the search box picks the first function shown.
  def handle_event("pick_first_function", %{"fq" => q}, socket) do
    socket = assign(socket, fn_query: q)

    case shown_functions(socket.assigns) do
      [{fun, arity, _exported?} | _] ->
        mfa = {socket.assigns.selected, fun, arity}

        picked =
          if mfa in socket.assigns.picked,
            do: socket.assigns.picked,
            else: socket.assigns.picked ++ [mfa]

        {:noreply, assign(socket, picked: picked, graph: nil)}

      [] ->
        {:noreply, socket}
    end
  end

  # Clicking a function picks it, or unpicks it if it was picked.
  def handle_event("select_function", %{"fun" => f, "arity" => a}, socket) do
    mfa = {socket.assigns.selected, String.to_existing_atom(f), String.to_integer(a)}
    {:noreply, assign(socket, picked: toggle_pick(socket.assigns.picked, mfa), graph: nil)}
  end

  def handle_event("unpick_all", _params, socket),
    do: {:noreply, assign(socket, picked: [], graph: nil)}

  # Starts a trace on every picked function not traced yet; the limit
  # applies to each.
  def handle_event("trace_picked", params, socket) do
    socket = assign(socket, call_limit: String.trim(params["limit"] || socket.assigns.call_limit))
    opts = if l = parse_limit(socket.assigns.call_limit), do: [limit: l], else: []
    traces = socket.assigns.traces

    result =
      socket.assigns.picked
      |> Enum.reject(&covered?(&1, traces))
      |> Enum.map(fn {m, f, a} -> Tracer.start_trace(m, f, a, opts) end)
      |> first_error()

    {:noreply,
     socket
     |> assign(traces: Tracer.traces(), limits: Tracer.limits(), notice: nil)
     |> result_to_error(result)}
  end

  def handle_event("stop_picked", _params, socket) do
    result =
      socket.assigns.picked
      |> Enum.filter(&(&1 in socket.assigns.traces))
      |> Enum.map(fn {m, f, a} -> Tracer.stop_trace(m, f, a) end)
      |> first_error()

    {:noreply,
     socket
     |> assign(traces: Tracer.traces(), limits: Tracer.limits(), notice: nil)
     |> result_to_error(result)}
  end

  def handle_event("toggle_trace", %{"mod" => m, "fun" => f, "arity" => a} = params, socket) do
    {mod, fun, arity} = mfa = parse_mfa(m, f, a)
    # a submit of the limit field brings its value along
    socket = assign(socket, call_limit: String.trim(params["limit"] || socket.assigns.call_limit))

    result =
      cond do
        mfa in socket.assigns.traces ->
          Tracer.stop_trace(mod, fun, arity)

        limit = parse_limit(socket.assigns.call_limit) ->
          Tracer.start_trace(mod, fun, arity, limit: limit)

        true ->
          Tracer.start_trace(mod, fun, arity)
      end

    {:noreply,
     socket
     |> assign(traces: Tracer.traces(), limits: Tracer.limits(), notice: nil)
     |> result_to_error(result)}
  end

  # The "stop after N calls" field: digits only, empty for no limit.
  def handle_event("call_limit", %{"limit" => limit}, socket),
    do: {:noreply, assign(socket, call_limit: String.trim(limit))}

  # Seq traces every picked function, or stops them all when all are on.
  def handle_event("toggle_seq_trace", _params, socket) do
    %{picked: picked, seq_traces: seq_traces, syntax: syntax} = socket.assigns

    {result, notice} =
      if all_seq?(picked, seq_traces) do
        {picked |> Enum.map(fn {m, f, a} -> SeqTracer.stop(m, f, a) end) |> first_error(), nil}
      else
        started = Enum.reject(picked, &(&1 in seq_traces))

        {started |> Enum.map(fn {m, f, a} -> SeqTracer.start(m, f, a) end) |> first_error(),
         "Seq tracing #{Enum.map_join(started, ", ", &Format.mfa(&1, syntax))}: messages their calls cause appear on the Seq trace page."}
      end

    {:noreply,
     socket
     |> assign(seq_traces: SeqTracer.traces(), notice: notice)
     |> result_to_error(result)}
  end

  def handle_event("call_graph", params, socket) do
    [{mod, fun, arity}] = socket.assigns.picked
    node = socket.assigns.node
    depth = socket.assigns.graph_depth
    force? = params["rebuild"] == "true"

    socket =
      socket
      |> assign(graph: {:loading, {mod, fun, arity}})
      |> start_async(:call_graph, fn ->
        with :ok <- CallGraph.index(node, force: force?) do
          CallGraph.analyse(node, mod, fun, arity, max_depth: depth)
        end
      end)

    {:noreply, socket}
  end

  def handle_event("graph_depth", %{"depth" => depth}, socket),
    do: {:noreply, assign(socket, graph_depth: String.to_integer(depth))}

  def handle_event("close_graph", _params, socket), do: {:noreply, assign(socket, graph: nil)}

  def handle_event("stop_all", _params, socket) do
    :ok = Tracer.stop_all()
    {:noreply, assign(socket, traces: [])}
  end

  def handle_event("clear_log", _params, socket) do
    :ok = Tracer.clear()
    {:noreply, socket |> stream(:entries, [], reset: true) |> assign(detail: nil)}
  end

  # A row's details open under it; clicking it again (or another row)
  # closes them. Only the rows that change are re-sent.
  def handle_event("show", %{"id" => id}, socket) do
    entry = Tracer.entry(String.to_integer(id))
    previous = socket.assigns.detail

    detail =
      if previous && entry && previous.id == entry.id,
        do: nil,
        else: entry

    socket = assign(socket, detail: detail)

    socket =
      if previous && (detail == nil or previous.id != detail.id) && in_log?(previous.id),
        do: stream_insert(socket, :entries, mark(Tracer.entry(previous.id) || previous, socket)),
        else: socket

    socket =
      if detail, do: stream_insert(socket, :entries, mark(detail, socket)), else: socket

    {:noreply, socket}
  end

  # the newest rows, as the log shows them
  defp log_rows(socket),
    do: Tracer.entries() |> Enum.take(@max_log_rows) |> Enum.map(&mark(&1, socket))

  # an entry with its details open or closed
  defp mark(entry, socket),
    do:
      Map.put(entry, :open, socket.assigns.detail != nil and socket.assigns.detail.id == entry.id)

  defp in_log?(id),
    do: Tracer.entries() |> Enum.take(@max_log_rows) |> Enum.any?(&(&1.id == id))

  @doc false
  # Called by BeamdashWeb.Syntax: the log is a stream, so re-send its rows.
  def syntax_changed(socket) do
    if connected?(socket),
      do: stream(socket, :entries, log_rows(socket), reset: true),
      else: socket
  end

  defp parse_limit(text) do
    case Integer.parse(text) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  # "_" / "_": every function of the module
  defp parse_mfa(m, "_", "_"), do: {String.to_existing_atom(m), :_, :_}

  defp parse_mfa(m, f, a),
    do: {String.to_existing_atom(m), String.to_existing_atom(f), String.to_integer(a)}

  @doc false
  # Adds or removes one picked function.
  def toggle_pick(picked, mfa),
    do: if(mfa in picked, do: List.delete(picked, mfa), else: picked ++ [mfa])

  # traced alone, or with every function of its module
  defp covered?({m, _, _} = mfa, traces), do: mfa in traces or {m, :_, :_} in traces

  defp all_seq?(picked, seq_traces), do: picked != [] and Enum.all?(picked, &(&1 in seq_traces))

  defp first_error(results), do: Enum.find(results, :ok, &match?({:error, _}, &1))

  defp result_to_error(socket, :ok), do: assign(socket, error: nil)
  defp result_to_error(socket, {:error, reason}), do: assign(socket, error: Format.error(reason))

  ## Async

  @impl true
  def handle_async(:call_graph, {:ok, {:ok, tree}}, socket),
    do: {:noreply, assign(socket, graph: {:ok, tree})}

  def handle_async(:call_graph, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, graph: {:error, Format.error(reason)})}

  def handle_async(:call_graph, {:exit, reason}, socket),
    do: {:noreply, assign(socket, graph: {:error, Format.error(reason)})}

  ## Messages

  @impl true
  def handle_info({:beamdash_trace, {:entry, entry}}, socket) do
    socket =
      if socket.assigns.detail && socket.assigns.detail.id == entry.id,
        do: assign(socket, detail: entry),
        else: socket

    {:noreply, stream_insert(socket, :entries, mark(entry, socket), at: 0, limit: @max_log_rows)}
  end

  def handle_info({:beamdash_trace, :traces_changed}, socket),
    do: {:noreply, assign(socket, traces: Tracer.traces(), limits: Tracer.limits())}

  def handle_info({:beamdash_trace, {:remaining, mfa, n}}, socket),
    do: {:noreply, assign(socket, limits: Map.put(socket.assigns.limits, mfa, n))}

  def handle_info({:beamdash_trace, {:limit_reached, mfa, limit}}, socket) do
    {:noreply,
     assign(socket,
       limits: Map.delete(socket.assigns.limits, mfa),
       notice:
         "#{Format.mfa(mfa, socket.assigns.syntax)} was called #{Format.number(limit)} time#{if limit != 1, do: "s"}: its trace has stopped."
     )}
  end

  def handle_info({:beamdash_trace, {:overload, queue_len}}, socket) do
    {:noreply,
     assign(socket,
       notice:
         "Tracing stopped: the target queued #{Format.number(queue_len)} trace messages faster than they could be handled. Trace fewer or less busy functions.",
       traces: []
     )}
  end

  def handle_info({:beamdash_trace, {:module_loaded, mod}}, socket) do
    {:noreply,
     assign(socket,
       notice:
         "#{Format.name(mod, socket.assigns.syntax)} was reloaded; its traces were re-applied."
     )}
  end

  def handle_info({:beamdash_trace, :cleared}, socket),
    do: {:noreply, stream(socket, :entries, [], reset: true)}

  def handle_info({:beamdash_seq, :traces_changed}, socket),
    do: {:noreply, assign(socket, seq_traces: SeqTracer.traces())}

  def handle_info({:beamdash_seq, _other}, socket), do: {:noreply, socket}

  def handle_info({:beamdash_target, {:connected, node}}, socket),
    do:
      {:noreply, socket |> assign(status: :connected, node: node) |> SourceTabs.init() |> load()}

  def handle_info({:beamdash_target, {:disconnected, _}}, socket) do
    {:noreply,
     socket
     |> SourceTabs.init()
     |> assign(
       status: :disconnected,
       modules: [],
       selected: nil,
       picked: [],
       traces: [],
       seq_traces: [],
       graph: nil
     )}
  end

  ## Rendering

  @impl true
  def render(assigns) do
    all = functions_of(assigns.modules, assigns.selected)
    shown = shown_functions(assigns)

    assigns =
      assign(assigns,
        fn_counts: %{
          all: length(all),
          exported: Enum.count(all, &elem(&1, 2)),
          local: Enum.count(all, &(!elem(&1, 2))),
          traced: Enum.count(all, &traced?(&1, assigns))
        },
        fn_groups:
          [
            {"Exported", Enum.filter(shown, &elem(&1, 2))},
            {"Not exported", Enum.reject(shown, &elem(&1, 2))}
          ]
          |> Enum.reject(fn {_title, fns} -> fns == [] end),
        fn_needle: needle(assigns.fn_query),
        shown_modules: matching_modules(assigns.modules, assigns.module_filter, assigns.syntax),
        functions: functions_of(assigns.modules, assigns.selected),
        # every function of the selected module traced at once
        wildcard: {assigns.selected, :_, :_},
        wildcard_on: {assigns.selected, :_, :_} in assigns.traces,
        module_traced_count:
          Enum.count(assigns.traces, &match?({m, _, _} when m == assigns.selected, &1)),
        to_trace: Enum.reject(assigns.picked, &covered?(&1, assigns.traces)),
        traced_picks: Enum.filter(assigns.picked, &(&1 in assigns.traces)),
        all_seq: all_seq?(assigns.picked, assigns.seq_traces),
        picked_modules: assigns.picked |> Enum.map(&elem(&1, 0)) |> MapSet.new()
      )

    ~H"""
    <main class="wrap">
      <BeamdashWeb.Layouts.header
        active={:trace}
        syntax={@syntax}
        conn={assigns[:conn]}
        ask={assigns[:ask]}
        ask_on={BeamdashWeb.JevSection.ask_on?(assigns[:jev_enabled])}
      />

      <p :if={@status != :connected} class="help">
        Not connected: enter a node above and click Connect.
      </p>

      <SourceTabs.tabs
        sources={@sources}
        current={@source_tab}
        main_label="Tracing"
        syntax={@syntax}
      />
      <SourceTabs.panel sources={@sources} current={@source_tab} syntax={@syntax} />

      <%!-- hidden, not removed, while a source is shown: the log is a stream --%>
      <div hidden={@source_tab != nil}>
        <p :if={@error} class="error">{@error}</p>
        <p :if={@notice} class="notice">{@notice}</p>

        <div :if={@status == :connected} class="trace-layout">
          <aside class="browser" id="module-browser">
            <div
              id="browser-resizer"
              class="resizer resizer-x resizer-right"
              phx-hook="Resizer"
              phx-update="ignore"
              data-var="--browser-w"
              data-axis="x"
              data-grow="right"
              data-target="#module-browser"
              data-container=".trace-layout"
              data-keep="360"
              data-min="180"
              data-max="900"
              role="separator"
              aria-orientation="vertical"
              aria-label="Resize the module list"
              tabindex="0"
              title="Drag to resize · double-click to reset"
            >
            </div>
            <form phx-change="filter_modules" phx-submit="filter_modules" class="filter">
              <input
                name="q"
                value={@module_filter}
                placeholder="Filter modules"
                phx-debounce="150"
                autocomplete="off"
              />
              <button
                type="button"
                class="secondary"
                phx-click="refresh_modules"
                title="Reload the module list"
              >
                ↻
              </button>
            </form>
            <p class="muted small">
              {length(@shown_modules)} of {Format.number(length(@modules))} loaded modules
            </p>
            <ul class="modules">
              <li
                :for={mod <- @shown_modules}
                class={[mod == @selected && "selected", mod in @picked_modules && "has-picks"]}
              >
                <a href="#" phx-click="select_module" phx-value-mod={mod}>
                  {Format.name(mod, @syntax)}
                </a>
              </li>
            </ul>
          </aside>

          <section class="trace-main">
            <div :if={@selected} class="functions">
              <div class="fn-head">
                <h2>{Format.name(@selected, @syntax)}</h2>
                <span class="muted small">
                  {@fn_counts.exported} exported · {@fn_counts.local} not exported
                </span>
                <button
                  :if={SourceTabs.available?(@source_known, @selected)}
                  type="button"
                  class="secondary small-btn"
                  phx-click="open_source"
                  phx-value-mod={@selected}
                  title="Open the module's source in a tab"
                >
                  Source
                </button>
              </div>

              <form
                class="fn-tools"
                phx-change="filter_functions"
                phx-submit="pick_first_function"
                role="search"
              >
                <input
                  type="search"
                  name="fq"
                  value={@fn_query}
                  placeholder="Search functions: name or name/arity"
                  phx-debounce="100"
                  autocomplete="off"
                  aria-label="Search functions"
                />
                <div class="seg" role="group" aria-label="Show">
                  <button
                    :for={
                      {f, label} <- [
                        all: "All",
                        exported: "Exported",
                        local: "Not exported",
                        traced: "Traced"
                      ]
                    }
                    type="button"
                    class={["seg-btn", @fn_filter == f && "active"]}
                    aria-pressed={to_string(@fn_filter == f)}
                    phx-click="fn_filter"
                    phx-value-f={f}
                  >
                    {label} <span class="muted">{@fn_counts[f]}</span>
                  </button>
                </div>
              </form>

              <div
                id="fn-panel"
                class="fn-panel"
                style="height: var(--fn-h, auto); max-height: var(--fn-h, 300px)"
              >
                <p :if={@fn_groups == []} class="muted small fn-none">
                  No functions match{if @fn_query != "", do: " “#{String.trim(@fn_query)}”"}{if @fn_filter !=
                                                                                                  :all,
                                                                                                do:
                                                                                                  " among #{filter_label(@fn_filter)} functions"}.
                </p>
                <section :for={{title, fns} <- @fn_groups} class="fn-group">
                  <h4>{title} <span class="muted">{length(fns)}</span></h4>
                  <ul class="fn-grid">
                    <li :for={{fun, arity, exported?} <- fns}>
                      <button
                        type="button"
                        class={[
                          "fn-row",
                          !exported? && "local",
                          {@selected, fun, arity} in @picked && "selected"
                        ]}
                        phx-click="select_function"
                        phx-value-fun={fun}
                        phx-value-arity={arity}
                        aria-pressed={to_string({@selected, fun, arity} in @picked)}
                      >
                        <span
                          :if={{@selected, fun, arity} in @picked}
                          class="fn-check"
                          aria-hidden="true"
                        >
                          ✓
                        </span>
                        <span class="fn-name mono">
                          <.highlight text={fn_name(fun, @syntax)} needle={@fn_needle} />
                        </span>
                        <span class="fn-arity mono">/{arity}</span>
                        <span :if={{@selected, fun, arity} in @traces} class="fn-badge trace">
                          trace{if n = @limits[{@selected, fun, arity}], do: " · #{n}"}
                        </span>
                        <span
                          :if={@wildcard_on}
                          class="fn-badge trace all"
                          title="Traced with every function of the module"
                        >
                          trace
                        </span>
                        <span :if={{@selected, fun, arity} in @seq_traces} class="fn-badge seq">
                          seq
                        </span>
                      </button>
                    </li>
                  </ul>
                </section>
              </div>
              <div
                id="fn-resizer"
                class="resizer resizer-y fn-resizer"
                phx-hook="Resizer"
                phx-update="ignore"
                data-var="--fn-h"
                data-axis="y"
                data-target="#fn-panel"
                data-min="80"
                data-max="2000"
                role="separator"
                aria-orientation="horizontal"
                aria-label="Resize the function list"
                tabindex="0"
                title="Drag to resize · double-click to reset"
              >
              </div>

              <div :if={@picked != []} class="fn-actions fn-picked" id="trace-picked">
                <div class="fn-picked-actions">
                  <form
                    :if={@to_trace != []}
                    class="call-limit"
                    phx-change="call_limit"
                    phx-submit="trace_picked"
                  >
                    <button type="submit" id="trace-picked-start">
                      {if length(@to_trace) == 1,
                        do: "Trace",
                        else: "Trace #{length(@to_trace)} functions"}
                    </button>
                    <label class="muted small">
                      stop after
                      <input
                        type="number"
                        name="limit"
                        min="1"
                        step="1"
                        value={@call_limit}
                        placeholder="∞"
                        inputmode="numeric"
                        aria-label="Stop each trace after this many calls (empty: no limit)"
                        title="Each function's trace stops after this many of its calls. Leave empty to trace until stopped."
                      /> calls{if length(@to_trace) > 1, do: " each"}
                    </label>
                  </form>
                  <button
                    :if={@traced_picks != []}
                    id="trace-picked-stop"
                    class="on"
                    phx-click="stop_picked"
                  >
                    {if length(@traced_picks) == 1,
                      do: "Stop trace",
                      else: "Stop #{length(@traced_picks)} traces"}
                  </button>
                  <button phx-click="toggle_seq_trace" class={@all_seq && "on"}>
                    {cond do
                      @all_seq and length(@picked) > 1 -> "Stop seq traces"
                      @all_seq -> "Stop seq trace"
                      true -> "Seq trace"
                    end}
                  </button>
                  <%= if length(@picked) == 1 do %>
                    <button phx-click="call_graph">Call graph</button>
                    <form phx-change="graph_depth" class="depth">
                      <label class="muted small">
                        depth
                        <select name="depth">
                          <option :for={d <- 2..10} value={d} selected={d == @graph_depth}>
                            {d}
                          </option>
                        </select>
                      </label>
                    </form>
                  <% else %>
                    <span class="muted small">Pick one function for its call graph.</span>
                  <% end %>
                  <button
                    :if={length(@picked) > 1}
                    type="button"
                    id="trace-picked-clear"
                    class="secondary"
                    phx-click="unpick_all"
                    title="Unpick all functions"
                  >
                    Clear selection
                  </button>
                </div>
              </div>
              <div :if={@picked == []} class="fn-actions fn-all">
                <%= cond do %>
                  <% @wildcard_on -> %>
                    <strong class="mono">{Format.mfa(@wildcard, @syntax)}</strong>
                    <span class="muted small">
                      all {@fn_counts.all} functions · {remaining_text(@limits, @wildcard)}
                    </span>
                    <button
                      phx-click="toggle_trace"
                      phx-value-mod={@selected}
                      phx-value-fun="_"
                      phx-value-arity="_"
                      class="on"
                    >
                      Stop trace
                    </button>
                  <% not Tracer.wildcard_allowed?(@selected) -> %>
                    <span class="muted small">
                      Click functions to pick them for tracing or seq tracing; pick one to see its call graph. (Tracing every function of {Format.name(
                        @selected,
                        @syntax
                      )} at once is not offered: the tracing itself runs in it.)
                    </span>
                  <% @module_traced_count > 0 -> %>
                    <span class="muted small">
                      Click functions to pick them for tracing or seq tracing; pick one to see its call graph. To trace every function, first stop the {@module_traced_count} traced here.
                    </span>
                  <% true -> %>
                    <span class="muted small">No function selected:</span>
                    <form class="call-limit" phx-change="call_limit" phx-submit="toggle_trace">
                      <input type="hidden" name="mod" value={@selected} />
                      <input type="hidden" name="fun" value="_" />
                      <input type="hidden" name="arity" value="_" />
                      <button
                        type="submit"
                        id="trace-all"
                        title={"Trace every call into #{Format.name(@selected, @syntax)}, local functions included (#{Format.mfa(@wildcard, @syntax)})"}
                      >
                        Trace all {@fn_counts.all} functions
                      </button>
                      <label class="muted small">
                        stop after
                        <input
                          type="number"
                          name="limit"
                          min="1"
                          step="1"
                          value={@call_limit}
                          placeholder="∞"
                          inputmode="numeric"
                          aria-label="Stop tracing after this many calls in total (empty: no limit)"
                          title="Calls of any function of the module count. Leave empty to trace until stopped."
                        /> calls
                      </label>
                    </form>
                    <span class="muted small fn-all-hint">
                      or click functions to pick just those. A busy module can produce many calls; tracing stops itself if the node can't keep up.
                    </span>
                <% end %>
              </div>
            </div>

            <div :if={@graph} class="graph">
              <div class="graph-head">
                <h3>Call graph</h3>
                <span :if={match?({:ok, _}, @graph)} class="muted small">
                  {CallGraph.size(elem(@graph, 1))} functions · calls into OTP and Elixir libraries are not expanded
                </span>
                <button class="secondary" phx-click="call_graph" phx-value-rebuild="true">
                  Rebuild index
                </button>
                <button class="secondary" phx-click="close_graph">Close</button>
              </div>
              <p :if={match?({:loading, _}, @graph)} class="muted">
                Analysing {Format.mfa(elem(@graph, 1), @syntax)}… The first call graph on a node builds an xref index of its code, which can take a while.
              </p>
              <p :if={match?({:error, _}, @graph)} class="error">{elem(@graph, 1)}</p>
              <ul :if={match?({:ok, _}, @graph)} class="tree">
                <.tree node={elem(@graph, 1)} syntax={@syntax} level={0} />
              </ul>
            </div>

            <div class="active-traces">
              <strong>Tracing:</strong>
              <span :if={@traces == []} class="muted">nothing</span>
              <span :for={{m, f, a} <- @traces} class="chip">
                {Format.mfa({m, f, a}, @syntax)}
                <span
                  :if={@limits[{m, f, a}]}
                  class="chip-count"
                  title="Calls left before the trace stops"
                >
                  {Format.number(@limits[{m, f, a}])} left
                </span>
                <a
                  href="#"
                  phx-click="toggle_trace"
                  phx-value-mod={m}
                  phx-value-fun={f}
                  phx-value-arity={a}
                  title="Stop"
                >
                  ×
                </a>
              </span>
              <button :if={@traces != []} class="secondary" phx-click="stop_all">Stop all</button>
              <button class="secondary" phx-click="clear_log">Clear log</button>
            </div>

            <div class="log" role="table" aria-label="Trace log">
              <div class="log-cols log-head" role="row">
                <span role="columnheader">Time (UTC)</span>
                <span role="columnheader">Process</span>
                <span role="columnheader">Call</span>
                <span role="columnheader">Result</span>
                <span role="columnheader" class="num">Duration</span>
              </div>
              <div id="trace-entries" phx-update="stream" role="rowgroup">
                <div
                  :for={{dom_id, e} <- @streams.entries}
                  id={dom_id}
                  class={["log-item", e[:open] && "open"]}
                >
                  <div
                    class={[
                      "log-cols log-row",
                      match?({:exception, _}, e.result) && "exception",
                      e.result == :pending && "pending"
                    ]}
                    role="row"
                    tabindex="0"
                    aria-expanded={to_string(e[:open] == true)}
                    phx-click="show"
                    phx-keydown="show"
                    phx-key="Enter"
                    phx-value-id={e.id}
                    title={if e[:open], do: "Hide details", else: "Show details"}
                  >
                    <span class="mono">{Format.time(e.call_us || e.return_us)}</span>
                    <span class="mono">
                      {if e.reg_name, do: Format.name(e.reg_name, @syntax), else: e.pid}
                    </span>
                    <span class="mono">{Format.call(e, @syntax)}</span>
                    <span class="mono">{Format.result(e.result, @syntax)}</span>
                    <span class="num">{Format.duration(e)}</span>
                  </div>
                  <div :if={e[:open]} class="detail log-detail" role="region">
                    <h3>
                      {Format.mfa({e.mod, e.fun, e.arity}, @syntax)}
                      <span class="muted">
                        in {e.pid}{if e.reg_name, do: " (#{e.reg_name})"}
                      </span>
                    </h3>
                    <div :if={e.args}>
                      <h4>Arguments</h4>
                      <pre :for={arg <- e.args}><%= Format.pretty(arg, @syntax) %></pre>
                    </div>
                    <h4>{result_heading(e.result)}</h4>
                    <pre><%= detail_result(e.result, @syntax) %></pre>
                    <div :if={e.stack != []}>
                      <h4>Call stack</h4>
                      <pre><%= Enum.map_join(e.stack, "\n", &Format.mfa(&1, @syntax)) %></pre>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </section>
        </div>
      </div>
    </main>
    """
  end

  # One call-graph node and, recursively, what it calls. The first two
  # levels start expanded.
  defp tree(assigns) do
    ~H"""
    <li>
      <%= case @node.calls do %>
        <% [] -> %>
          <span class="mono leaf">{Format.mfa(@node.mfa, @syntax)}</span>
        <% :more -> %>
          <span class="mono">{Format.mfa(@node.mfa, @syntax)}</span>
          <span class="muted small">… (depth limit)</span>
        <% calls -> %>
          <details open={@level < 2}>
            <summary class="mono">
              {Format.mfa(@node.mfa, @syntax)} <span class="muted small">{length(calls)}</span>
            </summary>
            <ul>
              <.tree :for={child <- calls} node={child} syntax={@syntax} level={@level + 1} />
            </ul>
          </details>
      <% end %>
    </li>
    """
  end

  defp remaining_text(limits, mfa) do
    case limits[mfa] do
      nil -> "traced until stopped"
      1 -> "1 call left"
      n -> "#{Format.number(n)} calls left"
    end
  end

  defp result_heading({:exception, _}), do: "Exception"
  defp result_heading(_), do: "Result"

  defp detail_result(:pending, _syntax), do: "(still running)"
  defp detail_result({:return, value}, syntax), do: Format.pretty(value, syntax)

  defp detail_result({:exception, {class, reason}}, syntax),
    do: "#{class}: " <> Format.pretty(reason, syntax)

  # The selected module's functions after the search and the filter.
  defp shown_functions(assigns) do
    needle = needle(assigns.fn_query)

    assigns.modules
    |> functions_of(assigns.selected)
    |> Enum.filter(fn {_f, _a, exported?} = fun ->
      case assigns.fn_filter do
        :all -> true
        :exported -> exported?
        :local -> not exported?
        :traced -> traced?(fun, assigns)
      end
    end)
    |> Enum.filter(&matches?(&1, needle, assigns.syntax))
  end

  defp traced?({f, a, _}, assigns),
    do:
      {assigns.selected, f, a} in assigns.traces or {assigns.selected, :_, :_} in assigns.traces or
        {assigns.selected, f, a} in assigns.seq_traces

  defp filter_label(:exported), do: "exported"
  defp filter_label(:local), do: "not exported"
  defp filter_label(:traced), do: "traced"
end
