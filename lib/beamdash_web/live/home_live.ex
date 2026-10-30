defmodule BeamdashWeb.HomeLive do
  @moduledoc """
  Connect form plus a live process table for the connected node. Clicking
  a process opens `BeamdashWeb.ProcessDetails` beside the table.
  """
  use Phoenix.LiveView

  alias Beamdash.{
    Apps,
    Format,
    ProcessAdvisor,
    ProcessStats,
    Settings,
    SysTracer,
    Target,
    TriageAdvisor
  }

  alias BeamdashWeb.{ProcessDetails, SourceTabs}

  @refresh_ms 2_000
  @detail_refresh_ms 1_000
  # Queued messages are fetched only up to this many, unless asked.
  @message_limit 100
  @message_limit_max 10_000
  @max_rows 500
  @sort_columns %{
    "name" => :name,
    "memory" => :memory,
    "reductions" => :reductions,
    "rate" => :reds_per_sec,
    "mq" => :message_queue_len
  }

  @impl true
  def mount(_params, _session, socket) do
    %{status: status, node: node} = Target.status()

    socket =
      assign(socket,
        jev_enabled: Settings.jev_enabled?(),
        jev_backend: Beamdash.Jev.backend(),
        process_advice: nil,
        process_advice_error: nil,
        process_advice_request: nil,
        process_evidence: nil,
        # Jev triage of the table: rolling history of the busiest processes
        triage_history: nil,
        # ?triage=1: run the triage as soon as there is enough history
        triage_auto: false,
        triage: %{request: nil, result: nil, error: nil, evidence: nil, only_flagged: false},
        status: status,
        node: node,
        node_input: if(node, do: Atom.to_string(node), else: ""),
        error: nil,
        info: nil,
        procs: [],
        sort_by: :reductions,
        sort_dir: :desc,
        filter: "",
        rates: %{},
        prev_sample: %{},
        prev_at: nil,
        selected: nil,
        details: nil,
        history: [],
        gc_result: nil,
        detail_note: nil,
        message_limit: @message_limit,
        sys_traced: MapSet.new(),
        sys_error: nil,
        dock_collapsed: false,
        # {kind, pid} of the maximized dock panel
        dock_active: nil,
        # state and supervisor-tree panels opened, [{:state | :tree, pid}]
        dock_extra: [],
        # the module that runs the selected process (Apps.module_summary/2)
        module_info: nil
      )
      |> SourceTabs.init()

    if connected?(socket) do
      :ok = Target.subscribe()
      :ok = SysTracer.subscribe()
      socket = assign(socket, sys_traced: MapSet.new(SysTracer.traced()))
      Process.send_after(self(), :tick, @refresh_ms)
      {:ok, if(status == :connected, do: refresh(socket), else: socket)}
    else
      {:ok, socket}
    end
  end

  # /?pid=<25432.85.0> (links from other pages) opens that process's details
  @impl true
  # ?pid= opens a process; ?sort=, ?q= and ?triage=1 come from links
  # (and "Ask beamdash")
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> then(fn s ->
        case @sort_columns[params["sort"]] do
          nil -> s
          col -> assign(s, sort_by: col, sort_dir: if(col == :name, do: :asc, else: :desc))
        end
      end)
      |> then(fn s -> if q = params["q"], do: assign(s, filter: q), else: s end)
      |> then(fn s -> if params["triage"] == "1", do: assign(s, triage_auto: true), else: s end)

    case params do
      %{"pid" => pid_string} ->
        if connected?(socket),
          do: handle_event("select", %{"pid" => pid_string}, socket),
          else: {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  ## Events

  @impl true
  # connect / disconnect: BeamdashWeb.Connection (the bar on every tab)

  ## Jev triage of the table

  def handle_event("triage", _params, %{assigns: %{triage: %{request: nil}}} = socket) do
    if match?({:ready, _}, TriageAdvisor.readiness(socket.assigns.triage_history)) do
      {:noreply, start_triage(socket)}
    else
      {:noreply,
       put_triage(socket,
         error: "Keep this page open a little longer: history is still being collected."
       )}
    end
  end

  def handle_event("triage", _params, socket), do: {:noreply, socket}

  def handle_event("triage_only", _params, socket),
    do: {:noreply, put_triage(socket, only_flagged: not socket.assigns.triage.only_flagged)}

  def handle_event("triage_clear", _params, socket), do: {:noreply, reset_triage(socket)}

  def handle_event("sort", %{"col" => col}, socket) do
    col = Map.fetch!(@sort_columns, col)

    dir =
      cond do
        socket.assigns.sort_by != col -> if col == :name, do: :asc, else: :desc
        socket.assigns.sort_dir == :desc -> :asc
        true -> :desc
      end

    {:noreply, assign(socket, sort_by: col, sort_dir: dir)}
  end

  # the selected process's module: its Source button opens it in a tab (see
  # BeamdashWeb.SourceTabs); only that module is taken from the browser
  def handle_event(event, params, socket)
      when event in ~w(open_source source_tab close_source) do
    modules =
      case socket.assigns.module_info do
        %{module: mod} -> [mod]
        nil -> []
      end

    {:noreply, SourceTabs.event(event, params, socket, modules)}
  end

  def handle_event("filter", %{"q" => q}, socket) do
    {:noreply, assign(socket, filter: q)}
  end

  # Legend items toggle a filter for their kind.
  def handle_event("filter_kind", %{"kind" => kind}, socket) do
    filter =
      if kind_filter(socket.assigns.filter) == String.to_existing_atom(kind), do: "", else: kind

    {:noreply, assign(socket, filter: filter)}
  end

  def handle_event("select", %{"pid" => pid_string}, socket) do
    case Target.parse_pid(pid_string, socket.assigns.node) do
      nil ->
        {:noreply, socket}

      pid ->
        socket =
          socket
          |> reset_process_advisor()
          |> assign(
            selected: pid,
            details: nil,
            history: [],
            gc_result: nil,
            detail_note: nil,
            message_limit: @message_limit,
            sys_error: nil,
            module_info: nil
          )

        send(self(), {:detail_tick, pid})
        {:noreply, socket}
    end
  end

  def handle_event("fetch_messages", _params, %{assigns: %{details: %{mailbox: mb}}} = socket) do
    limit = min(max(mb.length * 2, @message_limit), @message_limit_max)
    {:noreply, assign(socket, message_limit: limit)}
  end

  def handle_event("close_details", _params, socket),
    do:
      {:noreply,
       socket
       |> reset_process_advisor()
       |> assign(
         selected: nil,
         details: nil,
         history: [],
         gc_result: nil,
         sys_error: nil,
         module_info: nil
       )}

  # sys:trace(Pid, true | false) on the selected process.
  def handle_event("sys_trace", _params, %{assigns: %{selected: pid}} = socket)
      when is_pid(pid) do
    on? = MapSet.member?(socket.assigns.sys_traced, pid)
    result = if on?, do: SysTracer.disable(pid), else: SysTracer.enable(pid)

    case result do
      :ok -> {:noreply, assign(socket, sys_error: nil)}
      {:error, reason} -> {:noreply, assign(socket, sys_error: sys_error(reason, on?))}
    end
  end

  ## Dock: sys:trace, state and supervisor-tree panels

  # Makes a minimized panel the maximized one.
  def handle_event("dock_activate", %{"kind" => kind, "pid" => pid_string}, socket)
      when kind in ~w(trace state tree) do
    case Target.parse_pid(pid_string, socket.assigns.node) do
      nil ->
        {:noreply, socket}

      pid ->
        {:noreply,
         assign(socket, dock_active: {String.to_existing_atom(kind), pid}, dock_collapsed: false)}
    end
  end

  # The selected process's state / supervision tree, in a dock panel
  # (opened once per process; opening again brings it to the front).
  def handle_event("open_panel", %{"kind" => kind}, %{assigns: %{selected: pid}} = socket)
      when kind in ~w(state tree) and is_pid(pid) do
    entry = {String.to_existing_atom(kind), pid}
    extra = socket.assigns.dock_extra

    {:noreply,
     assign(socket,
       dock_extra: if(entry in extra, do: extra, else: extra ++ [entry]),
       dock_active: entry,
       dock_collapsed: false
     )}
  end

  def handle_event("dock_close", %{"kind" => kind, "pid" => pid_string}, socket)
      when kind in ~w(state tree) do
    entry = {String.to_existing_atom(kind), Target.parse_pid(pid_string, socket.assigns.node)}
    {:noreply, assign(socket, dock_extra: List.delete(socket.assigns.dock_extra, entry))}
  end

  def handle_event("dock_collapse", _params, socket),
    do: {:noreply, assign(socket, dock_collapsed: !socket.assigns.dock_collapsed)}

  def handle_event("gc", _params, %{assigns: %{selected: pid}} = socket) when is_pid(pid) do
    case Target.garbage_collect(pid) do
      {:ok, %{} = result} ->
        {:noreply, assign(socket, gc_result: result)}

      {:ok, :undefined} ->
        {:noreply,
         socket
         |> reset_process_advisor()
         |> assign(details: nil, detail_note: "The process has exited.")}

      {:error, reason} ->
        {:noreply, assign(socket, error: Format.error(reason))}
    end
  end

  def handle_event(
        "analyze_process",
        _,
        %{assigns: %{status: :connected, details: details, process_advice_request: nil}} = socket
      )
      when is_map(details) do
    cond do
      not Settings.jev_enabled?() ->
        {:noreply, socket |> assign(jev_enabled: false) |> reset_process_advisor()}

      match?({:collecting, _, _}, ProcessAdvisor.readiness(socket.assigns.history)) ->
        {:noreply,
         assign(socket,
           process_advice_error:
             "Keep the process selected a little longer: the history is still being collected."
         )}

      not Beamdash.Jev.configured?() ->
        {:noreply,
         assign(socket,
           process_advice_error:
             "Set TYPESAFE_API_KEY and restart beamdash to enable Jev analysis."
         )}

      true ->
        evidence =
          ProcessAdvisor.evidence(
            details,
            socket.assigns.history,
            Beamdash.Jev.Features.node_context(
              jev_rows(socket.assigns.procs, socket.assigns.rates),
              details.pid
            )
          )

        request = {:process_advisor, make_ref()}

        {:noreply,
         socket
         |> assign(
           process_advice: nil,
           process_advice_error: nil,
           process_evidence: evidence,
           process_advice_request: request
         )
         |> start_async(request, fn -> ProcessAdvisor.analyze(evidence) end)}
    end
  end

  def handle_event("analyze_process", _, socket), do: {:noreply, socket}

  defp sys_error(:timeout, false),
    do: "The process did not answer within 5 s (busy or blocked), so tracing was not switched on."

  defp sys_error(:timeout, true),
    do: "The process did not answer within 5 s; tracing switches off as soon as it does."

  defp sys_error(:noproc, _), do: "The process has exited."
  defp sys_error(reason, _), do: "sys:trace failed: #{Format.error(reason)}"

  @impl true
  def handle_async({:triage, _} = request, result, socket) do
    if request == socket.assigns.triage.request do
      socket = put_triage(socket, request: nil)

      case result do
        {:ok, {:ok, triage}} -> {:noreply, put_triage(socket, result: triage)}
        {:ok, {:error, message}} -> {:noreply, put_triage(socket, error: message)}
        {:exit, _} -> {:noreply, put_triage(socket, error: "The triage failed. Try again.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_async({:process_advisor, _} = request, result, socket) do
    if request == socket.assigns.process_advice_request and Settings.jev_enabled?() do
      socket = assign(socket, process_advice_request: nil)

      case result do
        {:ok, {:ok, advice}} ->
          {:noreply, assign(socket, process_advice: advice)}

        {:ok, {:error, message}} ->
          {:noreply, assign(socket, process_advice_error: message)}

        {:exit, _} ->
          {:noreply, assign(socket, process_advice_error: "Process analysis failed. Try again.")}
      end
    else
      {:noreply, socket}
    end
  end

  def jev_changed(%{assigns: %{jev_enabled: true}} = socket), do: socket
  def jev_changed(socket), do: socket |> reset_process_advisor() |> reset_triage()

  defp start_triage(socket) do
    {state, _questions, _ids} =
      req =
      TriageAdvisor.request(
        socket.assigns.procs,
        socket.assigns.rates,
        socket.assigns.triage_history
      )

    request = {:triage, make_ref()}

    socket
    |> assign(triage_auto: false)
    |> put_triage(request: request, error: nil, evidence: state)
    |> start_async(request, fn -> TriageAdvisor.analyze(req) end)
  end

  # ?triage=1: start once the history is long enough
  defp maybe_auto_triage(%{assigns: %{triage_auto: true, triage: %{request: nil}}} = socket) do
    if socket.assigns.jev_enabled and Beamdash.Jev.configured?() and
         match?({:ready, _}, TriageAdvisor.readiness(socket.assigns.triage_history)),
       do: start_triage(socket),
       else: socket
  end

  defp maybe_auto_triage(socket), do: socket

  defp put_triage(socket, changes),
    do: assign(socket, triage: Map.merge(socket.assigns.triage, Map.new(changes)))

  defp reset_triage(socket) do
    socket = if r = socket.assigns.triage.request, do: cancel_async(socket, r), else: socket

    assign(socket,
      triage: %{request: nil, result: nil, error: nil, evidence: nil, only_flagged: false}
    )
  end

  # Jev's verdict for a process, if the last triage flagged it
  defp flag(%{result: %{results: results}}, pid) do
    case results[pid] do
      %{flagged: true} = v -> v
      _ -> nil
    end
  end

  defp flag(_triage, _pid), do: nil

  defp reset_process_advisor(socket) do
    socket =
      if socket.assigns.process_advice_request,
        do: cancel_async(socket, socket.assigns.process_advice_request),
        else: socket

    assign(socket,
      process_advice: nil,
      process_advice_error: nil,
      process_advice_request: nil,
      process_evidence: nil
    )
  end

  # Pids in the table are printed as this node sees them ("<25518.86.0>"),
  # which list_to_pid/1 turns back into the same pid.
  # The process table as Jev.Features.node_context/2 wants it.
  defp jev_rows(procs, rates) do
    for p <- procs,
        do: %{
          pid: p.pid,
          memory: p.memory,
          queue: p.message_queue_len,
          rate: rates[p.pid],
          kind: Map.get(p, :kind)
        }
  end

  ## Messages

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @refresh_ms)
    {:noreply, if(socket.assigns.status == :connected, do: refresh(socket), else: socket)}
  end

  # Details of the selected process, every second while it stays selected.
  def handle_info({:detail_tick, pid}, %{assigns: %{selected: pid, status: :connected}} = socket) do
    case Target.process_details(pid, socket.assigns.message_limit) do
      {:ok, :undefined} ->
        {:noreply,
         socket
         |> reset_process_advisor()
         |> assign(details: nil, detail_note: "The process has exited.")}

      {:ok, details} ->
        Process.send_after(self(), {:detail_tick, pid}, @detail_refresh_ms)

        {:noreply,
         socket
         |> assign(
           details: details,
           history: ProcessStats.push(socket.assigns.history, details),
           detail_note: nil
         )
         |> module_info(details)}

      {:error, reason} ->
        Process.send_after(self(), {:detail_tick, pid}, @detail_refresh_ms)
        {:noreply, assign(socket, detail_note: Format.error(reason))}
    end
  end

  # A tick for a process no longer selected.
  def handle_info({:detail_tick, _pid}, socket), do: {:noreply, socket}

  def handle_info({:beamdash_sys_trace, pid, update}, socket) do
    traced =
      case update do
        :enabled -> MapSet.put(socket.assigns.sys_traced, pid)
        :disabled -> MapSet.delete(socket.assigns.sys_traced, pid)
        _ -> socket.assigns.sys_traced
      end

    # a process that has just been traced gets the maximized panel
    socket = if update == :enabled, do: assign(socket, dock_active: {:trace, pid}), else: socket

    {:noreply, socket |> assign(sys_traced: traced) |> dock_update(pid, update)}
  end

  def handle_info({:beamdash_target, {:connected, node}}, socket) do
    {:noreply,
     socket
     |> reset_process_advisor()
     |> reset_triage()
     |> SourceTabs.init()
     |> assign(triage_history: nil, prev_sample: %{}, prev_at: nil, rates: %{}, module_info: nil)
     |> assign(
       status: :connected,
       node: node,
       dock_extra: [],
       selected: nil,
       details: nil,
       history: []
     )
     |> refresh()}
  end

  def handle_info({:beamdash_target, {:disconnected, :nodedown}}, socket) do
    {:noreply,
     socket
     |> reset_process_advisor()
     |> reset_triage()
     |> SourceTabs.init()
     |> assign(triage_history: nil, prev_sample: %{}, prev_at: nil, rates: %{}, module_info: nil)
     |> assign(
       selected: nil,
       details: nil,
       history: [],
       status: :disconnected,
       info: nil,
       procs: [],
       # the connection bar says the connection was lost
       error: nil
     )}
  end

  def handle_info({:beamdash_target, {:disconnected, _}}, socket) do
    {:noreply,
     socket
     |> reset_process_advisor()
     |> reset_triage()
     |> SourceTabs.init()
     |> assign(triage_history: nil, prev_sample: %{}, prev_at: nil, rates: %{}, module_info: nil)
     |> assign(
       status: :disconnected,
       info: nil,
       procs: [],
       selected: nil,
       details: nil,
       history: []
     )}
  end

  @min_rate_window_us 1_000_000

  defp refresh(socket) do
    with {:ok, procs} <- Target.processes(),
         {:ok, info} <- Target.node_info() do
      now = System.monotonic_time(:microsecond)
      prev_at = socket.assigns.prev_at

      socket = assign(socket, procs: procs, info: info, error: nil)

      # Rates are only taken over at least @min_rate_window_us: over a
      # few milliseconds (two refreshes in a row, as on connect) the one
      # reduction it costs a process to be looked at reads as a high rate.
      if prev_at && now - prev_at < @min_rate_window_us do
        socket
      else
        elapsed = if prev_at, do: now - prev_at, else: 0
        {rates, sample} = ProcessStats.table_rates(procs, socket.assigns.prev_sample, elapsed)

        assign(socket,
          rates: rates,
          prev_sample: sample,
          prev_at: now,
          triage_history:
            if(prev_at,
              do: TriageAdvisor.track(socket.assigns.triage_history, procs, rates, now),
              else: socket.assigns.triage_history
            )
        )
        |> maybe_auto_triage()
      end
    else
      {:error, reason} -> assign(socket, error: Format.error(reason))
    end
  end

  ## Rendering

  @impl true
  def render(assigns) do
    matching = matching(assigns.procs, assigns.filter, assigns.sys_traced)

    matching =
      if assigns.triage.only_flagged,
        do: Enum.filter(matching, &flag(assigns.triage, &1.pid)),
        else: matching

    assigns = assign(assigns, rows: sort_rows(matching, assigns), match_count: length(matching))

    dock_panels =
      dock_panels(assigns.procs, assigns.sys_traced, assigns.dock_extra, assigns.syntax)

    assigns =
      assign(assigns,
        dock_panels: dock_panels,
        dock_active_pid: dock_active(dock_panels, assigns.dock_active)
      )

    ~H"""
    <main class={[
      "wrap",
      (@status == :connected and @dock_panels != []) &&
        if(@dock_collapsed, do: "has-dock-collapsed", else: "has-dock")
    ]}>
      <BeamdashWeb.Layouts.header
        active={:processes}
        syntax={@syntax}
        conn={assigns[:conn]}
        ask={assigns[:ask]}
        ask_on={BeamdashWeb.JevSection.ask_on?(assigns[:jev_enabled])}
      />

      <SourceTabs.tabs
        sources={@sources}
        current={@source_tab}
        main_label="Processes"
        syntax={@syntax}
      />
      <SourceTabs.panel sources={@sources} current={@source_tab} syntax={@syntax} />

      <%!-- hidden, not removed, while a source is shown: the panels keep their state --%>
      <div hidden={@source_tab != nil}>
        <p :if={@error} class="error">{@error}</p>

        <section :if={@status != :connected} class="help">
          <p>Start a node to inspect, for example:</p>
          <pre>erl -sname foo -setcookie abc</pre>
          <p>
            then connect to <code>foo</code>
            (or <code>foo@yourhost</code>) with cookie <code>abc</code>.
            beamdash joins as a hidden node, so it does not appear in the target's <code>nodes()</code>.
          </p>
        </section>

        <div :if={@status == :connected} class={["proc-layout", @selected && "with-panel"]}>
          <section class="proc-table">
            <form phx-change="filter" phx-submit="filter" class="filter">
              <input
                name="q"
                value={@filter}
                placeholder="Filter by name, pid or function"
                phx-debounce="200"
                autocomplete="off"
              />
              <span class="legend small" aria-label="Legend">
                <button
                  :for={kind <- BeamdashWeb.Icons.marked_kinds()}
                  type="button"
                  class={["legend-item", kind_filter(@filter) == kind && "active"]}
                  phx-click="filter_kind"
                  phx-value-kind={kind}
                  title={
                    if kind_filter(@filter) == kind,
                      do: "Show all processes",
                      else: "Show only #{kind} processes"
                  }
                >
                  <BeamdashWeb.Icons.kind kind={kind} />
                  {kind}
                  <span class="muted">{Format.number(
                    Enum.count(@procs, &(Map.get(&1, :kind) == kind))
                  )}</span>
                </button>
                <button
                  :if={MapSet.size(@sys_traced) > 0 or kind_filter(@filter) == :tracing}
                  type="button"
                  class={["legend-item", kind_filter(@filter) == :tracing && "active"]}
                  phx-click="filter_kind"
                  phx-value-kind="tracing"
                  title={
                    if kind_filter(@filter) == :tracing,
                      do: "Show all processes",
                      else: "Show only processes with sys:trace on"
                  }
                >
                  <span class="swatch-traced" aria-hidden="true"></span>
                  tracing
                  <span class="muted">{Format.number(
                    Enum.count(@procs, &MapSet.member?(@sys_traced, &1.pid))
                  )}</span>
                </button>
              </span>
              <span class="muted">
                {Format.number(@match_count)} of {Format.number(length(@procs))}{if @match_count >
                                                                                      length(@rows),
                                                                                    do:
                                                                                      " · showing first #{length(@rows)}"}
              </span>
            </form>

            <.triage_bar
              triage={@triage}
              readiness={TriageAdvisor.readiness(@triage_history)}
              enabled={@jev_enabled}
              configured={Beamdash.Jev.available?()}
              backend={@jev_backend}
            />

            <table>
              <thead>
                <tr>
                  <th>Pid</th>
                  <th class="sortable" phx-click="sort" phx-value-col="name">
                    Name / initial call{arrow(@sort_by, @sort_dir, :name)}
                  </th>
                  <th>Current function</th>
                  <th>Status</th>
                  <th class="num sortable" phx-click="sort" phx-value-col="mq">
                    Msg queue{arrow(@sort_by, @sort_dir, :message_queue_len)}
                  </th>
                  <th class="num sortable" phx-click="sort" phx-value-col="memory">
                    Memory{arrow(@sort_by, @sort_dir, :memory)}
                  </th>
                  <th class="num sortable" phx-click="sort" phx-value-col="reductions">
                    Reductions{arrow(@sort_by, @sort_dir, :reductions)}
                  </th>
                  <th
                    class="num sortable"
                    phx-click="sort"
                    phx-value-col="rate"
                    title="Reductions per second since the last refresh"
                  >
                    Reds/s{arrow(@sort_by, @sort_dir, :reds_per_sec)}
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={p <- @rows}
                  class={[
                    "clickable",
                    p.message_queue_len > 0 && "queued",
                    p.pid == @selected && "selected",
                    MapSet.member?(@sys_traced, p.pid) && "traced"
                  ]}
                  phx-click="select"
                  phx-value-pid={Format.pid(p.pid, :erlang)}
                >
                  <td class="mono">{Format.pid(p.pid, @syntax)}</td>
                  <td class={if p.registered_name, do: "named"}>
                    <BeamdashWeb.Icons.kind kind={Map.get(p, :kind)} />
                    {Format.label(p, @syntax)}
                    <span
                      :if={MapSet.member?(@sys_traced, p.pid)}
                      class="badge-trace"
                      title="sys:trace is on"
                    >
                      tracing
                    </span>
                    <span
                      :if={v = flag(@triage, p.pid)}
                      class="jev-flag"
                      title={"#{Beamdash.Jev.name(@jev_backend)}: #{v.label} (#{round(v.worth * 100)}% worth a look)#{if v.alternative, do: " or #{v.alternative.label}"}. Open the process for its own analysis."}
                    >
                      ⚑ {v.label}
                    </span>
                  </td>
                  <td class="mono muted">{Format.mfa(p.current_function, @syntax)}</td>
                  <td>{p.status}</td>
                  <td class="num">{Format.number(p.message_queue_len)}</td>
                  <td class="num">{Format.bytes(p.memory)}</td>
                  <td class="num">{Format.number(p.reductions)}</td>
                  <td class="num">{Format.number(@rates[p.pid])}</td>
                </tr>
              </tbody>
            </table>
          </section>

          <div :if={@selected} class="proc-side">
            <p :if={@detail_note} class="notice small">{@detail_note}</p>
            <p :if={!@details and !@detail_note} class="muted">Loading…</p>
            <ProcessDetails.panel
              :if={@details}
              details={@details}
              history={@history}
              syntax={@syntax}
              gc_result={@gc_result}
              module_info={@module_info}
              kind={kind_of(@procs, @selected)}
              sys_traced={MapSet.member?(@sys_traced, @selected)}
              names={proc_names(@procs)}
              sys_error={@sys_error}
              flag={BeamdashWeb.JevSection.show?(@jev_enabled) && flag(@triage, @selected)}
              jev={
                %{
                  enabled: @jev_enabled,
                  configured: Beamdash.Jev.configured?(),
                  busy: @process_advice_request != nil,
                  readiness: ProcessAdvisor.readiness(@history),
                  advice: @process_advice,
                  error: @process_advice_error,
                  evidence: @process_evidence
                }
              }
            />
          </div>
        </div>
      </div>
      <BeamdashWeb.SysDock.dock
        :if={@status == :connected and @dock_panels != []}
        panels={@dock_panels}
        active={@dock_active_pid}
        collapsed={@dock_collapsed}
        syntax={@syntax}
      />
    </main>
    """
  end

  # The module that runs the process, asked again only when it changes
  # (the details are refreshed every second).
  defp module_info(socket, details) do
    mod = Apps.process_module(details)

    case socket.assigns.module_info do
      %{module: ^mod} -> socket
      _ -> assign(socket, module_info: Apps.module_summary(socket.assigns.node, mod))
    end
  end

  # The kind a filter selects, or nil when it is not a kind name.
  # ("tracing" is not a behaviour: it lists the processes with sys:trace on)
  @kinds ~w(gen_server gen_statem gen_event supervisor tracing)

  defp kind_filter(filter) do
    needle = String.downcase(String.trim(filter))
    if needle in @kinds, do: String.to_existing_atom(needle)
  end

  # Each traced process has its own panel in the dock
  # (BeamdashWeb.SysPanel, a LiveComponent owning that process's event
  # stream); what SysTracer reports is passed on to it. :enabled and
  # :disabled only change the set of panels, which the render takes care of.
  defp dock_update(socket, pid, {:events, evs}),
    do: send_panel(socket, pid, new_events: evs)

  defp dock_update(socket, pid, {:dropped, n}), do: send_panel(socket, pid, dropped: n)
  defp dock_update(socket, pid, :cleared), do: send_panel(socket, pid, reload: true)
  defp dock_update(socket, _pid, _other), do: socket

  defp send_panel(socket, pid, update) do
    if MapSet.member?(socket.assigns.sys_traced, pid),
      do:
        send_update(
          BeamdashWeb.SysPanel,
          [id: "sys-panel-" <> BeamdashWeb.SysDock.key(pid)] ++ update
        )

    socket
  end

  # The maximized panel: the chosen one while it is open, else the first.
  defp dock_active([], _chosen), do: nil

  defp dock_active([first | _] = panels, chosen) do
    if Enum.any?(panels, &({&1.kind, &1.pid} == chosen)),
      do: chosen,
      else: {first.kind, first.pid}
  end

  # Dock panels: sys:trace panels of traced processes by name, then the
  # state and tree panels in the order they were opened.
  defp dock_panels(procs, traced, extra, syntax) do
    by_pid = Map.new(procs, &{&1.pid, &1})

    panel = fn kind, pid ->
      p = by_pid[pid]

      %{
        kind: kind,
        pid: pid,
        label: if(p, do: Format.label(p, syntax), else: Format.pid(pid, syntax)),
        proc_kind: p && Map.get(p, :kind)
      }
    end

    trace =
      traced
      |> Enum.map(&panel.(:trace, &1))
      |> Enum.sort_by(&String.downcase(&1.label))

    trace ++ Enum.map(extra, fn {kind, pid} -> panel.(kind, pid) end)
  end

  defp proc_names(procs),
    do: for(%{pid: pid, registered_name: name} <- procs, name, into: %{}, do: {pid, name})

  defp kind_of(procs, pid) do
    case Enum.find(procs, &(&1.pid == pid)) do
      %{kind: kind} -> kind
      _ -> nil
    end
  end

  defp arrow(col, :asc, col), do: " ▲"
  defp arrow(col, :desc, col), do: " ▼"
  defp arrow(_sort_by, _dir, _col), do: ""

  defp matching(procs, "", _traced), do: procs

  # A behaviour name on its own (gen_server, supervisor, ...) lists the
  # processes of that kind, "tracing" those being sys-traced; anything
  # else matches pid, name or function.
  defp matching(procs, filter, traced) do
    needle = String.downcase(String.trim(filter))

    case kind_filter(filter) do
      :tracing -> Enum.filter(procs, &MapSet.member?(traced, &1.pid))
      nil -> matching_text(procs, needle)
      kind -> Enum.filter(procs, &(Map.get(&1, :kind) == kind))
    end
  end

  defp matching_text(procs, needle) do
    Enum.filter(procs, fn p ->
      [Format.pid(p.pid), Format.label(p), Format.mfa(p.current_function)]
      |> Enum.any?(&String.contains?(String.downcase(&1), needle))
    end)
  end

  defp sort_rows(procs, %{sort_by: :name, sort_dir: dir}) do
    procs |> Enum.sort_by(&String.downcase(Format.label(&1)), dir) |> Enum.take(@max_rows)
  end

  defp sort_rows(procs, %{sort_by: :reds_per_sec, sort_dir: dir, rates: rates}) do
    procs |> Enum.sort_by(&(rates[&1.pid] || -1), dir) |> Enum.take(@max_rows)
  end

  defp sort_rows(procs, %{sort_by: col, sort_dir: dir}) do
    procs |> Enum.sort_by(&Map.get(&1, col), dir) |> Enum.take(@max_rows)
  end

  attr :triage, :map, required: true
  attr :readiness, :any, required: true
  attr :enabled, :boolean, required: true
  attr :configured, :boolean, required: true
  attr :backend, :atom, required: true

  # Jev triage above the table: the button, then how many processes were
  # flagged, with "only flagged" and what is sent.
  defp triage_bar(assigns) do
    assigns =
      assign(assigns,
        ready: match?({:ready, _}, assigns.readiness),
        flagged:
          case assigns.triage.result do
            %{results: r} -> Enum.count(r, fn {_pid, v} -> v.flagged end)
            _ -> 0
          end
      )

    ~H"""
    <div :if={@enabled and @configured} class="jev-triage" id="jev-triage">
      <button
        type="button"
        class="small-btn"
        phx-click="triage"
        disabled={@triage.request != nil or not @ready}
        title={"Ask #{Beamdash.Jev.name(@backend)} which of the busiest processes (up to #{TriageAdvisor.max_candidates()}) are worth a look"}
      >
        {cond do
          @triage.request -> "Triaging…"
          @triage.result -> "Triage again"
          true -> "#{Beamdash.Jev.name(@backend)}: triage busiest processes"
        end}
      </button>
      <span :if={not @ready and @triage.request == nil} class="muted small">
        collecting history · {elem(@readiness, 1)} of {elem(@readiness, 2)} s
      </span>
      <%= if r = @triage.result do %>
        <span class="small">
          <strong>{@flagged}</strong> of {r.count} worth a look
        </span>
        <button
          :if={@flagged > 0}
          type="button"
          class={["secondary small-btn", @triage.only_flagged && "on"]}
          phx-click="triage_only"
          aria-pressed={to_string(@triage.only_flagged)}
        >
          {if @triage.only_flagged, do: "Show all", else: "Show only flagged"}
        </button>
        <span class="muted small">
          over {r.window_s} s, at {Calendar.strftime(r.at, "%H:%M:%S")} UTC · {r.model} · suggestions, not diagnoses
        </span>
        <button type="button" class="secondary small-btn" phx-click="triage_clear">Clear</button>
      <% end %>
      <span :if={@triage.error} class="error small" role="alert">{@triage.error}</span>
      <details
        class="jev-sent"
        id="jev-triage-sent"
        phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["open"])}
      >
        <summary class="small muted">What is sent to {Beamdash.Jev.destination(@backend)}</summary>
        <p class="small muted">
          For each of the busiest processes, as an anonymous id (p1, p2, …): memory and queue trends, reductions rate, status, a wait category, OTP kind and rank on the node. Never pids, names, modules, stacks, messages or state. Sent only when you click; calls may be charged.
        </p>
        <pre :if={@triage.evidence} class="small">{Jason.encode!(@triage.evidence, pretty: true)}</pre>
      </details>
    </div>
    """
  end
end
