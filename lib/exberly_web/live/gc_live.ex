defmodule ExberlyWeb.GCLive do
  @moduledoc """
  The GC tab: node-wide collection rates, every process's heap and GC
  settings, and a process panel that looks and behaves like the one on the
  Processes tab (click a row to open it, live every second, resizable,
  closed with ×, `/gc?pid=<0.1.0>` opens it directly), focused on garbage
  collection: generations, sweeps, Force GC, GC trace and the Jev advisor.
  """
  use Phoenix.LiveView
  alias Exberly.{Format, GC, GCAdvisor, Settings, Target}
  alias ExberlyWeb.GCDetails

  @refresh_ms 2_000
  @detail_refresh_ms 1_000
  @trace_durations [1, 5, 10, 20, 30]
  @node_history 60
  @max_rows 200

  @impl true
  def mount(_params, _session, socket) do
    %{status: status, node: node} = Target.status()

    socket =
      socket
      |> assign(
        jev_enabled: Settings.jev_enabled?(),
        status: status,
        node: node,
        snap: nil,
        rates: nil,
        node_history: [],
        error: nil,
        paused: false,
        filter: "",
        sort: :memory,
        sort_dir: :desc,
        selected: nil,
        detail: nil,
        detail_note: nil,
        history: [],
        gc_result: nil,
        collector: nil,
        events: [],
        trace_status: nil,
        trace_seconds: 10,
        active_trace_seconds: 10
      )
      |> reset_advisor()

    if connected?(socket) do
      Target.subscribe()
      Process.send_after(self(), :tick, @refresh_ms)
    end

    {:ok, if(connected?(socket) and status == :connected, do: refresh(socket), else: socket)}
  end

  # /gc?pid=<0.1.0> opens that process's panel, as /?pid= does on Processes.
  @impl true
  def handle_params(%{"pid" => pid}, _uri, socket) do
    if connected?(socket) and socket.assigns.status == :connected,
      do: handle_event("select", %{"pid" => pid}, socket),
      else: {:noreply, socket}
  end

  # ?sort= comes from links ("Ask exberly")
  def handle_params(%{"sort" => col}, _uri, socket)
      when col in ~w(memory total_heap queued minor_gcs old_heap_size),
      do: {:noreply, assign(socket, sort: String.to_existing_atom(col), sort_dir: :desc)}

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  defp refresh(socket) do
    case GC.snapshot(socket.assigns.node) do
      {:ok, snap} ->
        rates = GC.rates(socket.assigns.snap, snap)

        assign(socket,
          snap: snap,
          rates: rates,
          error: nil,
          node_history:
            if(rates,
              do: Enum.take(socket.assigns.node_history ++ [rates], -@node_history),
              else: socket.assigns.node_history
            )
        )

      {:error, reason} ->
        assign(socket, error: Format.error(reason))
    end
  end

  ## Messages

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @refresh_ms)

    {:noreply,
     if(socket.assigns.status == :connected and not socket.assigns.paused,
       do: refresh(socket),
       else: socket
     )}
  end

  def handle_info({:detail_tick, pid}, %{assigns: %{selected: pid, status: :connected}} = socket) do
    # A negative mailbox limit: never copy queued messages.
    case Target.rpc(socket.assigns.node, :exberly_agent, :process_details, [pid, -1]) do
      {:ok, :undefined} ->
        {:noreply, assign(socket, detail: nil, detail_note: "The process has exited.")}

      {:ok, detail} ->
        Process.send_after(self(), {:detail_tick, pid}, @detail_refresh_ms)
        now = System.monotonic_time(:millisecond)
        origin = socket.assigns.sample_origin || now
        sample = Map.put(GCAdvisor.sample(detail), :offset_ms, now - origin)

        {:noreply,
         assign(socket,
           detail: detail,
           detail_note: nil,
           history: GCDetails.push(socket.assigns.history, detail),
           sample_origin: origin,
           samples: Enum.take(socket.assigns.samples ++ [sample], -60)
         )}

      {:error, reason} ->
        Process.send_after(self(), {:detail_tick, pid}, @detail_refresh_ms)
        {:noreply, assign(socket, detail_note: Format.error(reason))}
    end
  end

  # a tick for a process that is no longer selected
  def handle_info({:detail_tick, _pid}, socket), do: {:noreply, socket}

  def handle_info({:exberly_target, {:connected, node}}, socket) do
    GC.stop(socket.assigns.collector)

    {:noreply,
     socket
     |> unselect()
     |> assign(status: :connected, node: node, snap: nil, rates: nil, node_history: [])
     |> refresh()}
  end

  def handle_info({:exberly_target, {:disconnected, _}}, socket) do
    GC.stop(socket.assigns.collector)

    {:noreply,
     socket
     |> unselect()
     |> assign(status: :disconnected, node: nil, snap: nil, rates: nil, node_history: [])}
  end

  def handle_info({:gc_trace_event, collector, event}, socket) do
    if collector == socket.assigns.collector,
      do: {:noreply, assign(socket, events: Enum.take([event | socket.assigns.events], 200))},
      else: {:noreply, socket}
  end

  def handle_info({:gc_trace_done, collector, reason}, socket) do
    if collector == socket.assigns.collector,
      do: {:noreply, trace_ended(socket, "Finished: #{reason}")},
      else: {:noreply, socket}
  end

  def handle_info({:DOWN, _ref, :process, collector, reason}, socket) do
    if collector == socket.assigns.collector,
      do: {:noreply, trace_ended(socket, "Trace ended: #{inspect(reason)}")},
      else: {:noreply, socket}
  end

  defp trace_ended(socket, status),
    do:
      assign(socket,
        collector: nil,
        trace_status: status,
        trace_ended: System.monotonic_time(:millisecond)
      )

  ## Events

  @impl true
  def handle_event("pause", _, socket),
    do: {:noreply, assign(socket, paused: not socket.assigns.paused)}

  def handle_event("refresh", _, %{assigns: %{status: :connected}} = socket),
    do: {:noreply, refresh(socket)}

  def handle_event("filter", %{"q" => filter}, socket),
    do: {:noreply, assign(socket, filter: filter)}

  def handle_event("filter_kind", %{"kind" => kind}, socket) do
    filter = if String.trim(socket.assigns.filter) == kind, do: "", else: kind
    {:noreply, assign(socket, filter: filter)}
  end

  def handle_event("sort", %{"col" => col}, socket) do
    columns = [:name, :memory, :total_heap, :queued, :minor_gcs, :old_heap_size]

    case Enum.find(columns, &(Atom.to_string(&1) == col)) do
      nil ->
        {:noreply, socket}

      column ->
        direction =
          cond do
            socket.assigns.sort != column -> if column == :name, do: :asc, else: :desc
            socket.assigns.sort_dir == :desc -> :asc
            true -> :desc
          end

        {:noreply, assign(socket, sort: column, sort_dir: direction)}
    end
  end

  def handle_event("select", %{"pid" => value}, %{assigns: %{status: :connected}} = socket) do
    case parse_pid(value) do
      nil ->
        {:noreply, socket}

      pid ->
        send(self(), {:detail_tick, pid})
        {:noreply, socket |> unselect() |> assign(selected: pid)}
    end
  end

  def handle_event("close_details", _, socket), do: {:noreply, unselect(socket)}

  def handle_event("trace_duration", %{"duration" => d}, %{assigns: %{collector: nil}} = socket) do
    case parse_duration(d) do
      nil -> {:noreply, socket}
      seconds -> {:noreply, assign(socket, trace_seconds: seconds)}
    end
  end

  def handle_event("trace_duration", _, socket), do: {:noreply, socket}

  def handle_event(
        "trace",
        params,
        %{assigns: %{status: :connected, selected: pid, collector: nil}} = socket
      )
      when is_pid(pid) do
    seconds = parse_duration(Map.get(params, "duration", to_string(socket.assigns.trace_seconds)))

    if seconds == nil do
      {:noreply, assign(socket, error: "Choose a valid GC trace duration.")}
    else
      case GC.trace(socket.assigns.node, pid, self(), seconds) do
        {:ok, {:ok, collector}} ->
          Process.monitor(collector)

          {:noreply,
           assign(socket,
             collector: collector,
             events: [],
             trace_status: "Recording",
             trace_seconds: seconds,
             active_trace_seconds: seconds,
             error: nil,
             trace_started: System.monotonic_time(:millisecond),
             trace_ended: nil,
             trace_forced: 0
           )}

        {:ok, {:error, :already_traced}} ->
          {:noreply,
           assign(socket,
             trace_status: "Another tracer is attached to this process; it was left alone."
           )}

        {:ok, {:error, reason}} ->
          {:noreply, assign(socket, trace_status: "Could not trace: #{reason}")}

        {:error, reason} ->
          {:noreply, assign(socket, error: Format.error(reason))}
      end
    end
  end

  def handle_event("stop", _, socket) do
    GC.stop(socket.assigns.collector)
    {:noreply, socket}
  end

  def handle_event("collect", _, %{assigns: %{status: :connected, selected: pid}} = socket)
      when is_pid(pid) do
    case Target.rpc(socket.assigns.node, :exberly_agent, :garbage_collect, [pid]) do
      {:ok, %{before: before, after: after_}} ->
        {:noreply,
         assign(socket,
           gc_result: %{before: before, after: after_},
           trace_forced:
             socket.assigns.trace_forced + if(socket.assigns.collector, do: 1, else: 0)
         )}

      {:ok, :undefined} ->
        {:noreply, assign(socket, detail_note: "The process has exited.")}

      {:error, reason} ->
        {:noreply, assign(socket, error: Format.error(reason))}
    end
  end

  def handle_event(
        "analyze_gc",
        _,
        %{assigns: %{status: :connected, detail: detail, advisor_request: nil}} = socket
      )
      when is_map(detail) do
    cond do
      not Settings.jev_enabled?() ->
        {:noreply, socket |> assign(jev_enabled: false) |> jev_changed()}

      match?({:collecting, _, _}, GCAdvisor.readiness(socket.assigns.samples)) ->
        {:noreply,
         assign(socket,
           advisor_error:
             "Keep the process selected a little longer: the history is still being collected."
         )}

      Exberly.Jev.configured?() ->
        elapsed =
          if socket.assigns.trace_started do
            (socket.assigns.trace_ended || System.monotonic_time(:millisecond)) -
              socket.assigns.trace_started
          else
            0
          end

        evidence =
          GCAdvisor.evidence(
            detail,
            socket.assigns.samples,
            socket.assigns.events,
            elapsed,
            socket.assigns.trace_forced,
            socket.assigns.gc_result,
            Exberly.Jev.Features.node_context(jev_rows(socket.assigns.snap), detail.pid)
          )

        request = {:gc_advisor, make_ref()}

        {:noreply,
         socket
         |> assign(
           advisor: nil,
           advisor_error: nil,
           advisor_evidence: evidence,
           advisor_request: request
         )
         |> start_async(request, fn -> GCAdvisor.analyze(evidence) end)}

      true ->
        {:noreply,
         assign(socket,
           advisor_error: "Set TYPESAFE_API_KEY and restart exberly to enable Analyze GC."
         )}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def handle_async({:gc_advisor, _} = request, result, socket) do
    if request == socket.assigns.advisor_request and Settings.jev_enabled?() do
      socket = assign(socket, advisor_request: nil)

      case result do
        {:ok, {:ok, advice}} -> {:noreply, assign(socket, advisor: advice)}
        {:ok, {:error, message}} -> {:noreply, assign(socket, advisor_error: message)}
        {:exit, _} -> {:noreply, assign(socket, advisor_error: "GC analysis failed. Try again.")}
      end
    else
      {:noreply, socket}
    end
  end

  # Called by ExberlyWeb.Syntax when Jev is switched in Settings.
  def jev_changed(%{assigns: %{jev_enabled: true}} = socket), do: socket

  def jev_changed(socket) do
    socket =
      if socket.assigns.advisor_request,
        do: cancel_async(socket, socket.assigns.advisor_request),
        else: socket

    assign(socket, advisor: nil, advisor_request: nil, advisor_evidence: nil, advisor_error: nil)
  end

  # Closes the panel: stops its trace and forgets its samples and advice.
  defp unselect(socket) do
    GC.stop(socket.assigns.collector)

    socket
    |> reset_advisor()
    |> assign(
      selected: nil,
      detail: nil,
      detail_note: nil,
      history: [],
      gc_result: nil,
      collector: nil,
      events: [],
      trace_status: nil
    )
  end

  defp reset_advisor(socket) do
    socket =
      if socket.assigns[:advisor_request],
        do: cancel_async(socket, socket.assigns.advisor_request),
        else: socket

    assign(socket,
      advisor: nil,
      advisor_error: nil,
      advisor_request: nil,
      advisor_evidence: nil,
      samples: [],
      sample_origin: nil,
      trace_started: nil,
      trace_ended: nil,
      trace_forced: 0
    )
  end

  @impl true
  def terminate(_, socket), do: GC.stop(socket.assigns.collector)

  ## Rendering

  @impl true
  def render(assigns) do
    {rows, matching} =
      rows(assigns.snap, assigns.filter, assigns.sort, assigns.sort_dir, assigns.syntax)

    assigns = assign(assigns, rows: rows, match_count: matching)

    ~H"""
    <main class="wrap gc-page">
      <ExberlyWeb.Layouts.header
        active={:gc}
        syntax={@syntax}
        conn={assigns[:conn]}
        ask={assigns[:ask]}
        ask_on={ExberlyWeb.JevSection.show?(assigns[:jev_enabled])}
      />

      <p :if={@status != :connected} class="help">
        Not connected: enter a node above and click Connect to look at its garbage collection.
      </p>
      <p :if={@error} role="alert" class="error">{@error}</p>

      <section :if={@snap} class="gc-node" aria-label="Node-wide garbage collection">
        <div class="gc-tile">
          <span class="stat-label">Collections / s</span>
          <span class="stat-value">{if @rates, do: rate(@rates.collections), else: "…"}</span>
          <ExberlyWeb.ProcessDetails.sparkline
            id="gc-node-rate"
            title="Last two minutes"
            points={for r <- @node_history, do: r.collections}
            format={&rate/1}
          />
        </div>
        <div class="gc-tile">
          <span class="stat-label">Reclaimed / s</span>
          <span class="stat-value">{if @rates, do: Format.bytes(@rates.reclaimed), else: "…"}</span>
          <ExberlyWeb.ProcessDetails.sparkline
            id="gc-node-reclaimed"
            title="Last two minutes"
            points={for r <- @node_history, do: r.reclaimed}
            format={&Format.bytes/1}
          />
        </div>
        <div class="gc-tile">
          <span class="stat-label">Collections since boot</span>
          <span class="stat-value">{Format.number(@snap.collections)}</span>
          <span class="muted small">
            all processes, minor and full; trace a process to tell them apart
          </span>
        </div>
      </section>

      <div :if={@snap || @selected} class={["proc-layout", @selected && "with-panel"]}>
        <section :if={@snap} class="proc-table">
          <form phx-change="filter" phx-submit="filter" class="filter">
            <input
              type="search"
              name="q"
              value={@filter}
              placeholder="Filter by name, pid or function"
              phx-debounce="200"
              autocomplete="off"
              aria-label="Filter processes"
            />
            <span class="legend small" aria-label="Legend">
              <button
                :for={kind <- ExberlyWeb.Icons.marked_kinds()}
                type="button"
                class={["legend-item", String.trim(@filter) == Atom.to_string(kind) && "active"]}
                phx-click="filter_kind"
                phx-value-kind={kind}
              >
                <ExberlyWeb.Icons.kind kind={kind} />
                {kind}
                <span class="muted">{Format.number(Enum.count(@snap.processes, &(&1[:kind] == kind)))}</span>
              </button>
            </span>
            <span class="muted">
              {Format.number(@match_count)} of {Format.number(length(@snap.processes))}{if @match_count >
                                                                                             length(
                                                                                               @rows
                                                                                             ),
                                                                                           do:
                                                                                             " · showing first #{length(@rows)}"}
            </span>
            <span class="gc-sampling">
              <span :if={!@paused} class="muted small">every 2 s</span>
              <button
                type="button"
                class="secondary small-btn"
                phx-click="pause"
                title={
                  if @paused,
                    do: "Resume sampling",
                    else: "Sampling asks every process for its GC info"
                }
              >
                {if @paused, do: "Resume", else: "Pause"}
              </button>
              <button :if={@paused} type="button" class="secondary small-btn" phx-click="refresh">
                Refresh
              </button>
            </span>
          </form>

          <table class="gc-process-table">
            <thead>
              <tr>
                <th>Pid</th>
                <th class="sortable" phx-click="sort" phx-value-col="name">
                  Name / initial call{arrow(@sort, @sort_dir, :name)}
                </th>
                <th class="col-status">Status</th>
                <th
                  :for={
                    {col, label, title} <- [
                      {:queued, "Msg queue", "Messages waiting"},
                      {:memory, "Memory", "Process memory: heap, stack and internal data"},
                      {:total_heap, "Heap", "Young + old heap, allocated"},
                      {:old_heap_size, "Old heap", "Old generation, used"},
                      {:minor_gcs, "Minor GCs",
                       "Minor collections since the last full sweep, of fullsweep_after"}
                    ]
                  }
                  class="num sortable"
                  phx-click="sort"
                  phx-value-col={col}
                  title={title}
                >
                  {label}{arrow(@sort, @sort_dir, col)}
                </th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={p <- @rows}
                class={["clickable", p.queued > 0 && "queued", p.pid == @selected && "selected"]}
                phx-click="select"
                phx-value-pid={Format.pid(p.pid, :erlang)}
              >
                <td class="mono">{Format.pid(p.pid, @syntax)}</td>
                <td class={p.name && "named"}>
                  <ExberlyWeb.Icons.kind kind={p[:kind]} />
                  {process_name(p, @syntax)}
                </td>
                <td class="col-status">{p.status}</td>
                <td class="num">{Format.number(p.queued)}</td>
                <td class="num">{Format.bytes(p.memory)}</td>
                <td class="num">{Format.bytes(p.total_heap)}</td>
                <td class="num">{GCDetails.bytes(p.gc.old_heap_size)}</td>
                <td class="num" title={"of #{Format.number(p.gc.fullsweep_after)} (fullsweep_after)"}>
                  {Format.number(p.gc.minor_gcs)}<span
                    :if={p.gc.fullsweep_after != 65_535}
                    class="muted"
                  > / {Format.number(p.gc.fullsweep_after)}</span>
                </td>
              </tr>
            </tbody>
          </table>
          <p :if={@rows == []} class="muted">No matching processes.</p>
          <p class="muted small">
            Minor GCs restart from 0 after each full sweep, so they are not a collection rate.
            <span
              :if={Enum.any?(@snap.processes, &(&1.gc.fullsweep_after == 65_535))}
              class="muted"
            >fullsweep_after is shown when it is not the default 65,535.</span>
          </p>
        </section>

        <div :if={@selected} class="proc-side">
          <p :if={@detail_note} class="notice small">{@detail_note}</p>
          <p :if={!@detail and !@detail_note} class="muted">Loading…</p>
          <GCDetails.panel
            :if={@detail}
            details={@detail}
            history={@history}
            syntax={@syntax}
            kind={kind_of(@snap, @selected)}
            gc_result={@gc_result}
            trace={
              %{
                collector: @collector,
                events: @events,
                status: @trace_status,
                seconds: if(@collector, do: @active_trace_seconds, else: @trace_seconds),
                started: @trace_started
              }
            }
            trace_durations={trace_durations()}
            jev={
              %{
                enabled: @jev_enabled,
                configured: Exberly.Jev.configured?(),
                busy: @advisor_request != nil,
                readiness: GCAdvisor.readiness(@samples),
                advice: @advisor,
                error: @advisor_error,
                evidence: @advisor_evidence
              }
            }
          />
        </div>
      </div>

      <details
        :if={@snap}
        id="gc-guide"
        class="gc-guide"
        phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
      >
        <summary>What to look for</summary>
        <dl>
          <dt>Large binaries, small heap</dt>
          <dd>
            Force GC and compare. References nobody uses are released; a small
            sub-binary still keeps its whole parent alive: copy it with <code>binary:copy/1</code>
            (<code>:binary.copy/1</code>). <.link navigate="/memory">Memory → Binaries</.link>
            finds the holders across the node.
          </dd>
          <dt>Many idle processes holding memory</dt>
          <dd>
            Hibernation (<code>erlang:hibernate/3</code>, or OTP's <code>hibernate_after</code>)
            drops the stack and compacts the heap; live state is kept.
          </dd>
          <dt>Frequent full sweeps</dt>
          <dd>
            Trace a busy process and compare durations, old-heap use and binaries.
            <code>fullsweep_after</code>
            is set with spawn options or <code>process_flag/2</code>
            inside the process; it cannot be changed from outside.
          </dd>
          <dt>GC load across the node</dt>
          <dd>
            Microstate accounting (<code>msacc</code>) shows how much scheduler time goes to GC.
          </dd>
        </dl>
      </details>
    </main>
    """
  end

  # The GC sample as Jev.Features.node_context/2 wants it.
  defp jev_rows(nil), do: []

  defp jev_rows(snap),
    do:
      for(
        p <- snap.processes,
        do: %{pid: p.pid, memory: p.memory, queue: p.queued, rate: nil, kind: p[:kind]}
      )

  defp trace_durations, do: @trace_durations

  defp parse_duration(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds in @trace_durations -> seconds
      _ -> nil
    end
  end

  defp parse_duration(_), do: nil

  defp parse_pid(text) when is_binary(text) do
    if Regex.match?(~r/^<\d+\.\d+\.\d+>$/, text),
      do: :erlang.list_to_pid(String.to_charlist(text))
  end

  defp parse_pid(_), do: nil

  defp kind_of(nil, _pid), do: nil

  defp kind_of(snap, pid),
    do: Enum.find_value(snap.processes, fn p -> if p.pid == pid, do: p[:kind] end)

  # {rows to show, how many match}
  defp rows(nil, _, _, _, _), do: {[], 0}

  defp rows(snap, filter, sort, direction, syntax) do
    needle = filter |> String.trim() |> String.downcase()
    kinds = Enum.map(ExberlyWeb.Icons.marked_kinds(), &Atom.to_string/1)

    matching =
      Enum.filter(snap.processes, fn p ->
        cond do
          needle == "" ->
            true

          needle in kinds ->
            Atom.to_string(p[:kind] || :none) == needle

          true ->
            text =
              "#{p.name} #{Format.pid(p.pid, :erlang)} #{Format.pid(p.pid, :elixir)} " <>
                "#{Format.mfa(p.initial_call, :erlang)} #{Format.mfa(p.initial_call, :elixir)} " <>
                "#{Format.mfa(p.current_function, :erlang)} #{Format.mfa(p.current_function, :elixir)}"

            String.contains?(String.downcase(text), needle)
        end
      end)

    sorted =
      Enum.sort_by(
        matching,
        fn p ->
          cond do
            sort == :name -> String.downcase(process_name(p, syntax))
            sort in [:minor_gcs, :old_heap_size] -> num(p.gc[sort])
            true -> p[sort]
          end
        end,
        direction
      )

    {Enum.take(sorted, @max_rows), length(matching)}
  end

  defp num(n) when is_integer(n), do: n
  defp num(_), do: 0

  defp process_name(%{name: name, initial_call: initial_call}, syntax),
    do: if(name, do: Format.name(name, syntax), else: Format.mfa(initial_call, syntax))

  defp rate(n) when is_float(n) and n < 10, do: Float.round(n, 1) |> to_string()
  defp rate(n) when is_number(n), do: Format.number(round(n))
  defp rate(_), do: "…"

  defp arrow(column, :asc, column), do: " ▲"
  defp arrow(column, :desc, column), do: " ▼"
  defp arrow(_, _, _), do: ""
end
