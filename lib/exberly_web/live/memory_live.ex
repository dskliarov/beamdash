defmodule ExberlyWeb.MemoryLive do
  @moduledoc """
  Memory of the connected node: an `erlang:memory()` breakdown refreshed
  every 2 s with its trend, limits, and a leak investigation per kind of
  memory (processes, binaries, ETS), using recon where possible
  (`Exberly.Memory`).
  """
  use Phoenix.LiveView

  alias Exberly.{Format, Memory, MemoryAdvisor, Target}
  alias ExberlyWeb.ProcessDetails

  @refresh_ms 2_000
  # 5 minutes of 2 s samples
  @history 150
  @ets_refresh_ms 5_000

  # The parts erlang:memory() splits `total` into, in this (fixed) order;
  # each has its own colour (see app.css, --mem-*).
  @parts [
    processes: "Processes",
    binary: "Binaries",
    ets: "ETS",
    code: "Code",
    atom: "Atoms",
    other: "Other system"
  ]

  @attrs [
    memory: "Memory",
    message_queue_len: "Message queue",
    binary_memory: "Binary memory",
    reductions: "Reductions"
  ]

  @impl true
  def mount(_params, _session, socket) do
    %{status: status, node: node} = Target.status()

    socket =
      assign(socket,
        status: status,
        node: node,
        snap: nil,
        history: [],
        recon: nil,
        error: nil,
        tab: nil,
        attr: :memory,
        top_n: 10,
        top: nil,
        top_prev: %{},
        gc: nil,
        leaks: nil,
        busy: nil,
        ets: nil,
        ets_base: %{},
        ets_prev: %{},
        ets_sort: {:memory, :desc},
        ets_filter: "",
        inspect: nil,
        # Jev: which kind of memory needs attention
        health: %{request: nil, advice: nil, error: nil, evidence: nil},
        # ?check=1: run the health check as soon as there is enough history
        health_auto: false
      )

    if connected?(socket) do
      :ok = Target.subscribe()
      Process.send_after(self(), :tick, @refresh_ms)
      Process.send_after(self(), :ets_tick, @ets_refresh_ms)
      {:ok, if(status == :connected, do: start(socket), else: socket)}
    else
      {:ok, socket}
    end
  end

  defp start(socket) do
    socket
    |> assign(recon: Memory.recon_status(socket.assigns.node))
    |> refresh()
    |> then(fn s -> assign(s, tab: s.assigns.tab || suggested_tab(s.assigns.snap)) end)
    |> load_tab()
  end

  ## Data

  defp refresh(socket) do
    case Memory.snapshot(socket.assigns.node) do
      {:ok, snap} ->
        point = %{at: snap.sampled_at_ms, memory: snap.memory}

        assign(socket,
          snap: snap,
          history: Enum.take(socket.assigns.history ++ [point], -@history),
          error: nil
        )

      {:error, reason} ->
        assign(socket, error: Format.error(reason))
    end
  end

  defp load_tab(%{assigns: %{tab: :ets}} = socket), do: load_ets(socket)
  defp load_tab(%{assigns: %{tab: nil}} = socket), do: socket
  defp load_tab(socket), do: load_top(socket)

  defp load_top(socket) do
    attr = if socket.assigns.tab == :binary, do: :binary_memory, else: socket.assigns.attr

    case Memory.top_processes(socket.assigns.node, attr, socket.assigns.top_n) do
      {:ok, {source, entries}} ->
        prev =
          case socket.assigns.top do
            %{attr: ^attr, entries: old} -> Map.new(old, &{&1.pid, &1.value})
            _ -> %{}
          end

        assign(socket, top: %{attr: attr, source: source, entries: entries}, top_prev: prev)

      {:error, reason} ->
        assign(socket, error: Format.error(reason))
    end
  end

  defp load_ets(socket) do
    case Memory.ets_tables(socket.assigns.node) do
      {:ok, tables} ->
        now = Map.new(tables, &{&1.id, &1})
        # growth is measured against the first time a table was seen here
        base = Map.merge(now, socket.assigns.ets_base, fn _id, _new, old -> old end)
        prev = socket.assigns.ets || []
        assign(socket, ets: tables, ets_base: base, ets_prev: Map.new(prev, &{&1.id, &1}))

      {:error, reason} ->
        assign(socket, error: Format.error(reason))
    end
  end

  # The investigation to open first: the biggest of processes, binaries
  # and ETS.
  defp suggested_tab(nil), do: :processes

  defp suggested_tab(%{memory: m}) do
    [processes: m.processes, binary: m.binary, ets: m.ets]
    |> Enum.max_by(&elem(&1, 1))
    |> elem(0)
  end

  # ?tab=processes|binary|ets and ?check=1 come from links ("Ask exberly")
  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      case params["tab"] do
        tab when tab in ~w(processes binary ets) ->
          socket = assign(socket, tab: String.to_existing_atom(tab), inspect: nil, top: nil)

          if socket.assigns.status == :connected and connected?(socket),
            do: load_tab(socket),
            else: socket

        _ ->
          socket
      end

    {:noreply, if(params["check"] == "1", do: assign(socket, health_auto: true), else: socket)}
  end

  ## Events

  @impl true
  def handle_event("tab", %{"tab" => tab}, socket) when tab in ~w(processes binary ets) do
    {:noreply,
     socket |> assign(tab: String.to_existing_atom(tab), inspect: nil, top: nil) |> load_tab()}
  end

  def handle_event("attr", %{"attr" => attr, "n" => n}, socket) do
    attr = Enum.find(Keyword.keys(@attrs), :memory, &(Atom.to_string(&1) == attr))
    n = if n in ~w(5 10 20 50), do: String.to_integer(n), else: 10
    {:noreply, socket |> assign(attr: attr, top_n: n, top: nil) |> load_top()}
  end

  def handle_event("refresh_top", _params, socket), do: {:noreply, load_top(socket)}

  def handle_event("gc_all", _params, socket) do
    socket = assign(socket, busy: :gc)

    case Memory.gc_all(socket.assigns.node) do
      {:ok, gc} -> {:noreply, socket |> assign(gc: gc, busy: nil) |> refresh() |> load_top()}
      {:error, r} -> {:noreply, assign(socket, error: Format.error(r), busy: nil)}
    end
  end

  def handle_event("bin_leak", _params, socket) do
    case Memory.binary_leaks(socket.assigns.node, socket.assigns.top_n) do
      {:ok, leaks} -> {:noreply, socket |> assign(leaks: leaks) |> refresh() |> load_top()}
      {:error, r} -> {:noreply, assign(socket, error: Format.error(r))}
    end
  end

  def handle_event("inspect", %{"pid" => pid_text}, socket) do
    with pid when is_pid(pid) <- parse_pid(pid_text),
         {:ok, %{} = state} <- Memory.process_state(socket.assigns.node, pid, false) do
      {:noreply, assign(socket, inspect: Map.put(state, :pid, pid))}
    else
      {:ok, :undefined} ->
        {:noreply, assign(socket, inspect: nil, error: "The process has exited.")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("get_status", _params, %{assigns: %{inspect: %{pid: pid}}} = socket) do
    case Memory.process_state(socket.assigns.node, pid, true) do
      {:ok, %{} = state} ->
        {:noreply, assign(socket, inspect: Map.put(state, :pid, pid))}

      {:ok, :undefined} ->
        {:noreply, assign(socket, inspect: nil, error: "The process has exited.")}

      {:error, r} ->
        {:noreply, assign(socket, error: Format.error(r))}
    end
  end

  def handle_event("close_inspect", _params, socket), do: {:noreply, assign(socket, inspect: nil)}

  def handle_event(
        "analyze_memory",
        _params,
        %{assigns: %{snap: snap, health: %{request: nil}}} = socket
      )
      when is_map(snap) do
    if match?({:ready, _}, MemoryAdvisor.readiness(socket.assigns.history)) do
      {:noreply, start_health(socket)}
    else
      {:noreply,
       put_health(socket,
         error: "Keep this page open a little longer: history is still being collected."
       )}
    end
  end

  def handle_event("analyze_memory", _params, socket), do: {:noreply, socket}

  def handle_event("ets_sort", %{"col" => col}, socket) when col in ~w(name size memory growth) do
    col = String.to_existing_atom(col)

    dir =
      case socket.assigns.ets_sort do
        {^col, :desc} -> :asc
        {^col, :asc} -> :desc
        _ -> if col == :name, do: :asc, else: :desc
      end

    {:noreply, assign(socket, ets_sort: {col, dir})}
  end

  def handle_event("ets_filter", %{"q" => q}, socket),
    do: {:noreply, assign(socket, ets_filter: q)}

  def handle_event("ets_reset", _params, socket),
    do: {:noreply, assign(socket, ets_base: Map.new(socket.assigns.ets || [], &{&1.id, &1}))}

  @impl true
  def handle_async({:memory_advisor, _} = request, result, socket) do
    if request == socket.assigns.health.request do
      socket = put_health(socket, request: nil)

      case result do
        {:ok, {:ok, advice}} -> {:noreply, put_health(socket, advice: advice)}
        {:ok, {:error, message}} -> {:noreply, put_health(socket, error: message)}
        {:exit, _} -> {:noreply, put_health(socket, error: "The health check failed. Try again.")}
      end
    else
      {:noreply, socket}
    end
  end

  # Called by ExberlyWeb.Syntax when Jev is switched in Settings.
  def jev_changed(%{assigns: %{jev_enabled: true}} = socket), do: socket

  def jev_changed(socket) do
    socket =
      if r = socket.assigns.health.request, do: cancel_async(socket, r), else: socket

    assign(socket, health: %{request: nil, advice: nil, error: nil, evidence: nil})
  end

  defp start_health(socket) do
    evidence = MemoryAdvisor.evidence(socket.assigns.snap, socket.assigns.history)
    request = {:memory_advisor, make_ref()}

    socket
    |> assign(health_auto: false)
    |> assign(health: %{request: request, advice: nil, error: nil, evidence: evidence})
    |> start_async(request, fn -> MemoryAdvisor.analyze(evidence) end)
  end

  defp maybe_auto_health(
         %{assigns: %{health_auto: true, snap: snap, health: %{request: nil}}} = socket
       )
       when is_map(snap) do
    if socket.assigns.jev_enabled and Exberly.Jev.configured?() and
         match?({:ready, _}, MemoryAdvisor.readiness(socket.assigns.history)),
       do: start_health(socket),
       else: socket
  end

  defp maybe_auto_health(socket), do: socket

  defp put_health(socket, changes),
    do: assign(socket, health: Map.merge(socket.assigns.health, Map.new(changes)))

  ## Messages

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @refresh_ms)

    {:noreply,
     if(socket.assigns.status == :connected,
       do: socket |> refresh() |> maybe_auto_health(),
       else: socket
     )}
  end

  def handle_info(:ets_tick, socket) do
    Process.send_after(self(), :ets_tick, @ets_refresh_ms)

    {:noreply,
     if(socket.assigns.status == :connected and socket.assigns.tab == :ets,
       do: load_ets(socket),
       else: socket
     )}
  end

  def handle_info({:exberly_target, {:connected, node}}, socket),
    do: {:noreply, socket |> assign(status: :connected, node: node, history: []) |> start()}

  def handle_info({:exberly_target, {:disconnected, _}}, socket),
    do: {:noreply, assign(socket, status: :disconnected, snap: nil, top: nil, ets: nil)}

  defp parse_pid(text) do
    if Regex.match?(~r/^<\d+\.\d+\.\d+>$/, text),
      do: :erlang.list_to_pid(String.to_charlist(text))
  end

  ## Rendering

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        parts_list: @parts,
        attrs: @attrs,
        parts: if(assigns.snap, do: parts(assigns.snap.memory), else: [])
      )

    ~H"""
    <main class="wrap">
      <ExberlyWeb.Layouts.header
        active={:memory}
        syntax={@syntax}
        conn={assigns[:conn]}
        ask={assigns[:ask]}
        ask_on={ExberlyWeb.JevSection.show?(assigns[:jev_enabled])}
      />

      <p :if={@status != :connected} class="help">
        Not connected: enter a node above and click Connect.
      </p>
      <p :if={@error} class="error">{@error}</p>

      <section :if={@snap} class="memory">
        <div class="mem-hero">
          <div>
            <span class="mem-total">{Format.bytes(@snap.memory.total)}</span>
            <span class="muted">in use by the VM · <code>erlang:memory()</code></span>
          </div>
          <div :if={@snap.alloc} class="muted small">
            Allocated from the OS: {Format.bytes(@snap.alloc.allocated)} · used {Format.bytes(
              @snap.alloc.used
            )} ({Float.round(@snap.alloc.usage * 100, 1)}%) <span class="muted">· recon_alloc</span>
          </div>
        </div>

        <div class="mem-bar" role="img" aria-label={bar_label(@parts)}>
          <span
            :for={{key, label, bytes, pct} <- @parts}
            :if={pct > 0}
            class={["mem-seg", "mem-#{key}"]}
            style={"flex-grow: #{bytes}"}
            title={"#{label}: #{Format.bytes(bytes)} (#{pct}%)"}
          ></span>
        </div>
        <ul class="mem-legend" aria-hidden="true">
          <li :for={{key, label, _bytes, pct} <- @parts}>
            <span class={["mem-swatch", "mem-#{key}"]}></span>{label}
            <span class="muted">{pct}%</span>
          </li>
        </ul>

        <table class="mem-table">
          <thead>
            <tr>
              <th>Kind</th>
              <th class="num">Size</th>
              <th class="num">Share</th>
              <th class="num">Last 5 min</th>
              <th>Trend</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{key, label, bytes, pct} <- @parts}>
              <td>
                <span class={["mem-swatch", "mem-#{key}"]}></span>{label}
                <span :if={key == :processes} class="muted small">
                  ({Format.bytes(@snap.memory.processes_used)} used)
                </span>
                <span :if={key == :atom} class="muted small">
                  ({Format.bytes(@snap.memory.atom_used)} used)
                </span>
              </td>
              <td class="num">{Format.bytes(bytes)}</td>
              <td class="num">{pct}%</td>
              <td class={["num", growth_class(growth(@history, key))]}>
                {growth_text(growth(@history, key))}
              </td>
              <td class="trend">
                <ProcessDetails.sparkline
                  id={"mem-spark-#{key}"}
                  title={label}
                  points={for p <- @history, do: part_bytes(p.memory, key)}
                  format={&Format.bytes/1}
                  from_zero={false}
                />
              </td>
            </tr>
          </tbody>
        </table>

        <div class="mem-limits">
          <.meter
            label="Atoms"
            used={@snap.atom_count}
            limit={@snap.atom_limit}
            hint="atoms are never freed; at the limit the node crashes"
          />
          <.meter label="Processes" used={@snap.process_count} limit={@snap.process_limit} hint="" />
          <.meter
            :if={@snap.ets_limit}
            label="ETS tables"
            used={@snap.ets_count}
            limit={@snap.ets_limit}
            hint=""
          />
          <div class="meter">
            <span class="meter-label">Modules loaded</span>
            <span class="mono">{Format.number(@snap.module_count)}</span>
          </div>
        </div>

        <div :if={ExberlyWeb.JevSection.show?(@jev_enabled)} class="jev-card">
          <ExberlyWeb.JevSection.section
            id="jev-memory"
            event="analyze_memory"
            title="Jev: node memory health"
            sends="Per kind of memory: size, share of the total, change and growth per second over the window; atom, process and ETS-table counts against their limits; allocated vs used."
            enabled={@jev_enabled}
            configured={Exberly.Jev.configured?()}
            busy={@health.request != nil}
            readiness={MemoryAdvisor.readiness(@history)}
            advice={@health.advice}
            error={@health.error}
            evidence={@health.evidence}
          />
          <p :if={@health.advice && @health.advice.view} class="jev-goto">
            <button
              type="button"
              class="small-btn"
              phx-click="tab"
              phx-value-tab={@health.advice.view}
            >
              Look for a leak in {MemoryAdvisor.choices()[@health.advice.choice].label} ↓
            </button>
          </p>
        </div>

        <h2 class="mem-h2">Look for a leak</h2>
        <p class="muted small recon-status">{recon_text(@recon)}</p>

        <nav class="seg mem-tabs" role="tablist">
          <button
            :for={
              {tab, label, part} <-
                [
                  processes: {"Processes", :processes},
                  binary: {"Binaries", :binary},
                  ets: {"ETS tables", :ets}
                ]
                |> Enum.map(fn {t, {l, p}} -> {t, l, p} end)
            }
            type="button"
            role="tab"
            aria-selected={to_string(@tab == tab)}
            class={["seg-btn", @tab == tab && "active"]}
            phx-click="tab"
            phx-value-tab={tab}
          >
            <span class={["mem-swatch", "mem-#{part}"]}></span>{label}
            <span class="muted">{Format.bytes(Map.fetch!(@snap.memory, part))}</span>
          </button>
        </nav>

        <div :if={@tab == :processes} class="mem-panel">
          <p class="guide">
            Memory held by processes: usually messages piling up in a mailbox nobody reads,
            or a process whose state keeps growing. Find the biggest ones, then look at what
            they are doing and holding.
          </p>
          <form phx-change="attr" class="top-form">
            <label class="muted small">
              Top
              <select name="n">
                <option :for={n <- [5, 10, 20, 50]} value={n} selected={n == @top_n}>{n}</option>
              </select>
              by
              <select name="attr">
                <option
                  :for={{a, label} <- @attrs}
                  :if={a != :binary_memory}
                  value={a}
                  selected={a == @attr}
                >
                  {label}
                </option>
              </select>
            </label>
            <button type="button" class="secondary small-btn" phx-click="refresh_top">Refresh</button>
            <span :if={@top} class="muted small mono">{source_call(@top)}</span>
          </form>
          <.top_table :if={@top} top={@top} prev={@top_prev} syntax={@syntax} />
          <.inspect_panel :if={@inspect} p={@inspect} syntax={@syntax} />
        </div>

        <div :if={@tab == :binary} class="mem-panel">
          <p class="guide">
            Binaries over 64 bytes live in a shared heap and are freed only when no process
            refers to them. A process that keeps a small slice of a big binary keeps all of it;
            a process that rarely collects keeps binaries it has finished with.
          </p>
          <div class="mem-actions">
            <button phx-click="gc_all" phx-disable-with="Collecting…">
              Garbage collect every process
            </button>
            <button class="secondary" phx-click="bin_leak" phx-disable-with="Collecting…">
              Find binary leaks <span class="mono small">recon:bin_leak({@top_n})</span>
            </button>
          </div>
          <.gc_result :if={@gc} gc={@gc} />
          <div :if={@leaks} class="leaks">
            <p class={["small", leak_class(@leaks)]}>
              Binary memory {Format.bytes(@leaks.binary_before)} → {Format.bytes(@leaks.binary_after)} ({drop_text(
                @leaks.binary_before,
                @leaks.binary_after
              )}) after collecting every process.
              Processes that released the most binary references <span class="muted">({if @leaks.source == :recon, do: "recon:bin_leak", else: "built-in"})</span>:
            </p>
            <.top_table
              top={%{attr: :binary_refs, source: @leaks.source, entries: @leaks.processes}}
              prev={%{}}
              syntax={@syntax}
            />
          </div>
          <h3 class="mem-h3">Holding the most binary memory now</h3>
          <.top_table :if={@top} top={@top} prev={@top_prev} syntax={@syntax} />
          <p class="guide small">
            The fix for a slice that keeps a big binary alive: copy it out before keeping it,
            <code>binary:copy/1</code>
            (Elixir <code>:binary.copy/1</code>).
          </p>
          <.inspect_panel :if={@inspect} p={@inspect} syntax={@syntax} />
        </div>

        <div :if={@tab == :ets} class="mem-panel">
          <p class="guide">
            ETS tables are never garbage collected: rows stay until deleted or the owner dies.
            A table that keeps growing is the leak. Growth is counted from when you opened this
            page (or reset it); the list refreshes every 5 s.
          </p>
          <.ets_table
            :if={@ets}
            tables={@ets}
            base={@ets_base}
            sort={@ets_sort}
            filter={@ets_filter}
            syntax={@syntax}
          />
        </div>
      </section>
    </main>
    """
  end

  ## Components

  attr :label, :string, required: true
  attr :used, :integer, required: true
  attr :limit, :integer, required: true
  attr :hint, :string, default: ""

  defp meter(assigns) do
    assigns = assign(assigns, pct: Float.round(assigns.used * 100 / max(assigns.limit, 1), 1))

    ~H"""
    <div class={["meter", @pct >= 80 && "warn"]} title={@hint}>
      <span class="meter-label">{@label}</span>
      <span class="mono">{Format.number(@used)} / {Format.number(@limit)}</span>
      <span class="meter-track"><span style={"width: #{min(@pct, 100)}%"}></span></span>
      <span class="muted small">{@pct}%{if @pct >= 80, do: " · near the limit"}</span>
    </div>
    """
  end

  attr :top, :map, required: true
  attr :prev, :map, required: true
  attr :syntax, :atom, required: true

  defp top_table(assigns) do
    # for these, a process with nothing to show is noise
    entries =
      if assigns.top.attr in [:binary_memory, :binary_refs, :message_queue_len],
        do: Enum.filter(assigns.top.entries, &(&1.value > 0)),
        else: assigns.top.entries

    assigns = assign(assigns, entries: entries)

    ~H"""
    <table class="top-table">
      <thead>
        <tr>
          <th>Process</th>
          <th class="num">{value_heading(@top.attr)}</th>
          <th class="num">Change</th>
          <th>Running</th>
          <th></th>
        </tr>
      </thead>
      <tbody>
        <tr :for={e <- @entries}>
          <td>
            <span class={e.name && "named"}>
              {if e.name, do: Format.name(e.name, @syntax), else: Format.mfa(e.initial_call, @syntax)}
            </span>
            <span class="muted small mono">{Format.pid(e.pid, @syntax)}</span>
          </td>
          <td class="num">{value_text(@top.attr, e.value)}</td>
          <td class={["num", change_class(@prev[e.pid], e.value)]}>
            {change_text(@top.attr, @prev[e.pid], e.value)}
          </td>
          <td class="mono muted small">{Format.mfa(e.current_function, @syntax)}</td>
          <td class="row-actions">
            <button
              class="secondary small-btn"
              phx-click="inspect"
              phx-value-pid={Format.pid(e.pid, :erlang)}
            >
              Inspect
            </button>
            <.link navigate={"/?pid=" <> Format.pid(e.pid, :erlang)} class="small">Details</.link>
          </td>
        </tr>
      </tbody>
    </table>
    <p :if={@entries == []} class="muted small">{empty_text(@top.attr)}</p>
    """
  end

  attr :p, :map, required: true
  attr :syntax, :atom, required: true

  defp inspect_panel(assigns) do
    ~H"""
    <div class="inspect" id="inspect">
      <div class="inspect-head">
        <h3 class="mono">
          {if @p.name, do: Format.name(@p.name, @syntax), else: Format.pid(@p.pid, @syntax)}
        </h3>
        <span class="muted small">
          {Format.bytes(@p.memory)} · {Format.number(@p.message_queue_len)} queued
        </span>
        <button class="secondary small-btn" phx-click="close_inspect" aria-label="Close">×</button>
      </div>
      <h4>
        Current stack <span class="muted mono small">process_info(Pid, current_stacktrace)</span>
      </h4>
      <pre class="small">{stack_text(@p.stack, @syntax)}</pre>
      <h4>State <span class="muted mono small">sys:get_status(Pid)</span></h4>
      <%= case @p.status do %>
        <% :not_requested -> %>
          <p class="small">
            <button class="secondary small-btn" phx-click="get_status">Get state</button>
            <span class="muted">
              Sends the process a system message (OTP processes only; others time out after 2 s).
            </span>
          </p>
        <% {:ok, status} -> %>
          <pre class="small status-pre">{Format.pretty(status, @syntax)}</pre>
        <% {:error, reason} -> %>
          <p class="muted small">No state: {Format.term(reason, @syntax)}</p>
      <% end %>
    </div>
    """
  end

  attr :gc, :map, required: true

  defp gc_result(assigns) do
    ~H"""
    <table class="gc-table">
      <thead>
        <tr>
          <th>After collecting every process</th>
          <th class="num">Before</th>
          <th class="num">After</th>
          <th class="num">Freed</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={{k, label} <- [total: "Total", processes: "Processes", binary: "Binaries"]}>
          <td>{label}</td>
          <td class="num">{Format.bytes(@gc.before[k])}</td>
          <td class="num">{Format.bytes(@gc.after[k])}</td>
          <td class={["num", @gc.before[k] - @gc.after[k] > @gc.before[k] * 0.1 && "freed"]}>
            {drop_text(@gc.before[k], @gc.after[k])}
          </td>
        </tr>
      </tbody>
    </table>
    <p class="muted small">
      If binary memory dropped a lot, processes were holding binaries they no longer used:
      “Find binary leaks” shows which.
    </p>
    """
  end

  attr :tables, :list, required: true
  attr :base, :map, required: true
  attr :sort, :any, required: true
  attr :filter, :string, required: true
  attr :syntax, :atom, required: true

  defp ets_table(assigns) do
    needle = assigns.filter |> String.trim() |> String.downcase()

    rows =
      assigns.tables
      |> Enum.map(fn t ->
        base = Map.get(assigns.base, t.id, t)
        Map.merge(t, %{growth: t.memory - base.memory, rows_growth: t.size - base.size})
      end)
      |> Enum.filter(fn t ->
        needle == "" or String.contains?(String.downcase(table_name(t)), needle) or
          String.contains?(String.downcase(owner_text(t, :erlang)), needle)
      end)
      |> sort_ets(assigns.sort)

    total = Enum.reduce(assigns.tables, 0, &(&1.memory + &2))
    assigns = assign(assigns, rows: rows, total: total)

    ~H"""
    <div class="ets-tools">
      <form phx-change="ets_filter" phx-submit="ets_filter">
        <input
          type="search"
          name="q"
          value={@filter}
          placeholder="Filter by table or owner"
          phx-debounce="150"
          autocomplete="off"
        />
      </form>
      <span class="muted small">
        {length(@tables)} tables · {Format.bytes(@total)}
      </span>
      <button class="secondary small-btn" phx-click="ets_reset" title="Count growth from now">
        Reset growth
      </button>
    </div>
    <table class="ets-table">
      <thead>
        <tr>
          <th class="sortable" phx-click="ets_sort" phx-value-col="name">
            Table{arrow(@sort, :name)}
          </th>
          <th>Owner</th>
          <th>Type</th>
          <th class="num sortable" phx-click="ets_sort" phx-value-col="size">
            Rows{arrow(@sort, :size)}
          </th>
          <th class="num sortable" phx-click="ets_sort" phx-value-col="memory">
            Memory{arrow(@sort, :memory)}
          </th>
          <th class="num sortable" phx-click="ets_sort" phx-value-col="growth">
            Growth{arrow(@sort, :growth)}
          </th>
        </tr>
      </thead>
      <tbody>
        <tr :for={t <- @rows} class={t.growth > 0 && "growing"}>
          <td class="mono">{table_name(t)}</td>
          <td class="small">
            <.link navigate={"/?pid=" <> Format.pid(t.owner, :erlang)}>{owner_text(t, @syntax)}</.link>
          </td>
          <td class="muted small">{t.type}, {t.protection}</td>
          <td class="num">{Format.number(t.size)}</td>
          <td class="num">{Format.bytes(t.memory)}</td>
          <td class={["num", change_class(0, t.growth)]}>
            {if t.growth == 0, do: "–", else: signed_bytes(t.growth)}
            <span :if={t.rows_growth != 0} class="muted small">
              ({if t.rows_growth > 0, do: "+"}{Format.number(t.rows_growth)} rows)
            </span>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  ## Helpers

  # The memory parts, as {key, label, bytes, percent of total}.
  defp parts(m) do
    other = m.system - m.atom - m.binary - m.code - m.ets

    for {key, label} <- @parts do
      bytes = if key == :other, do: max(other, 0), else: Map.fetch!(m, key)
      {key, label, bytes, Float.round(bytes * 100 / max(m.total, 1), 1)}
    end
  end

  defp part_bytes(m, :other), do: max(m.system - m.atom - m.binary - m.code - m.ets, 0)
  defp part_bytes(m, key), do: Map.fetch!(m, key)

  defp bar_label(parts),
    do:
      "Memory by kind: " <>
        Enum.map_join(parts, ", ", fn {_, l, b, p} -> "#{l} #{Format.bytes(b)} (#{p}%)" end)

  # Change over the history window (up to 5 minutes).
  defp growth([], _key), do: nil
  defp growth([_], _key), do: nil

  defp growth(history, key),
    do: part_bytes(List.last(history).memory, key) - part_bytes(hd(history).memory, key)

  defp growth_text(nil), do: "–"
  defp growth_text(0), do: "±0"
  defp growth_text(n), do: signed_bytes(n)

  defp growth_class(n) when is_integer(n) and n > 1_048_576, do: "up"
  defp growth_class(n) when is_integer(n) and n < -1_048_576, do: "down"
  defp growth_class(_), do: nil

  defp signed_bytes(n) when n > 0, do: "+" <> Format.bytes(n)
  defp signed_bytes(n), do: "−" <> Format.bytes(-n)

  defp drop_text(before, after_) when before > 0 and after_ < before,
    do: "−#{Format.bytes(before - after_)}, #{Float.round((before - after_) * 100 / before, 1)}%"

  defp drop_text(before, after_) when after_ > before, do: "+#{Format.bytes(after_ - before)}"
  defp drop_text(_, _), do: "no change"

  defp leak_class(%{binary_before: b, binary_after: a}) when b > 0 and (b - a) / b > 0.1,
    do: "freed"

  defp leak_class(_), do: nil

  defp empty_text(:binary_memory), do: "No process holds binary memory now."
  defp empty_text(:binary_refs), do: "No process released any binaries."
  defp empty_text(:message_queue_len), do: "No process has messages waiting."
  defp empty_text(_), do: "Nothing to show."

  defp value_heading(:memory), do: "Memory"
  defp value_heading(:message_queue_len), do: "Queued"
  defp value_heading(:binary_memory), do: "Binary memory"
  defp value_heading(:reductions), do: "Reductions"
  defp value_heading(:binary_refs), do: "Released"

  defp value_text(attr, v) when attr in [:memory, :binary_memory], do: Format.bytes(v)

  defp value_text(:binary_refs, v),
    do: "#{Format.number(v)} binar#{if v == 1, do: "y", else: "ies"}"

  defp value_text(_attr, v), do: Format.number(v)

  defp change_text(_attr, nil, _v), do: ""
  defp change_text(_attr, same, same), do: "–"

  defp change_text(attr, prev, v) when attr in [:memory, :binary_memory],
    do: signed_bytes(v - prev)

  defp change_text(_attr, prev, v), do: if(v > prev, do: "+", else: "") <> Format.number(v - prev)

  defp change_class(nil, _), do: nil
  defp change_class(prev, v) when v > prev, do: "up"
  defp change_class(prev, v) when v < prev, do: "down"
  defp change_class(_, _), do: nil

  defp source_call(%{source: :recon, attr: attr, entries: e}),
    do: "recon:proc_count(#{attr}, #{length(e)})"

  defp source_call(%{source: :builtin}), do: "built-in (recon not available)"

  defp recon_text(:node), do: "Investigating with recon, the node's own copy."
  defp recon_text(:loaded), do: "Investigating with recon, loaded into the node by exberly."

  defp recon_text(:builtin),
    do:
      "recon is not available (run mix deps.get for exberly), so exberly's built-in equivalents are used."

  defp recon_text(nil), do: ""

  defp stack_text(stack, syntax) when is_list(stack) do
    Enum.map_join(stack, "\n", fn
      {m, f, a, loc} ->
        where = if loc[:file], do: "  (#{loc[:file]}:#{loc[:line]})", else: ""
        Format.mfa({m, f, a}, syntax) <> where

      other ->
        Format.term(other, syntax)
    end)
  end

  defp stack_text(_, _), do: ""

  defp table_name(%{named: true, name: name}), do: Atom.to_string(name)
  defp table_name(%{name: name, id: id}), do: "#{name} #{inspect(id)}"

  defp owner_text(%{owner_name: name, owner: pid}, syntax) when is_atom(name) and name != nil,
    do: "#{Format.name(name, syntax)} #{Format.pid(pid, syntax)}"

  defp owner_text(%{owner: pid}, syntax), do: Format.pid(pid, syntax)

  defp sort_ets(rows, {:name, dir}), do: Enum.sort_by(rows, &String.downcase(table_name(&1)), dir)
  defp sort_ets(rows, {col, dir}), do: Enum.sort_by(rows, &Map.fetch!(&1, col), dir)

  defp arrow({col, :asc}, col), do: " ▲"
  defp arrow({col, :desc}, col), do: " ▼"
  defp arrow(_sort, _col), do: ""
end
