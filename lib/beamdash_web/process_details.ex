defmodule BeamdashWeb.ProcessDetails do
  @moduledoc """
  The process detail panel: memory, garbage collection, reductions and the
  mailbox of one process, plus small trend charts of the last minute.
  """
  use Phoenix.Component

  alias Beamdash.Format
  alias Phoenix.LiveView.JS

  # Processes that answer sys requests (sys:trace and friends)
  @sys_kinds [:gen_server, :gen_statem, :gen_event, :supervisor]

  attr :details, :map, required: true
  attr :history, :list, required: true
  attr :syntax, :atom, required: true
  attr :gc_result, :map, default: nil
  attr :module_info, :map, default: nil, doc: "`Beamdash.Apps.module_summary/2` of its module"
  attr :kind, :atom, default: nil
  attr :sys_traced, :boolean, default: false
  attr :sys_error, :string, default: nil
  attr :names, :map, default: %{}, doc: "pid => registered name, for labelling linked processes"

  attr :flag, :map,
    default: nil,
    doc: "the last triage's verdict when it flagged this process: how to follow it up"

  attr :jev, :map,
    default: nil,
    doc: "%{enabled, configured, busy, readiness, advice, error, evidence}; nil hides Jev"

  def panel(assigns) do
    assigns =
      assign(assigns,
        rate: assigns.history |> List.last() |> then(&(&1 && &1.reds_per_sec)),
        mem: assigns.details.memory,
        gc: assigns.details.gc,
        mailbox: assigns.details.mailbox
      )

    ~H"""
    <aside class="proc-panel" id="process-details">
      <div
        id="panel-resizer"
        class="resizer resizer-x"
        phx-hook="Resizer"
        phx-update="ignore"
        data-var="--panel-w"
        data-axis="x"
        data-target="#process-details"
        data-container=".proc-layout"
        data-keep="320"
        data-min="300"
        data-max="1400"
        role="separator"
        aria-orientation="vertical"
        aria-label="Resize the process panel"
        tabindex="0"
        title="Drag to resize · double-click to reset"
      >
      </div>
      <div class="panel-head">
        <div>
          <h3 class="mono">
            <BeamdashWeb.Icons.kind kind={@kind} />
            {if @details.registered_name,
              do: Format.name(@details.registered_name, @syntax),
              else: Format.pid(@details.pid, @syntax)}
          </h3>
          <p class="muted small mono">
            {Format.pid(@details.pid, @syntax)} · {Format.mfa(@details.initial_call, @syntax)}
          </p>
        </div>
        <div class="panel-actions">
          <button
            :if={sys_kind?(@kind)}
            type="button"
            role="switch"
            aria-checked={to_string(@sys_traced)}
            class={["switch", @sys_traced && "on"]}
            phx-click="sys_trace"
            title={
              if @sys_traced,
                do: "sys:trace(Pid, false)",
                else: "sys:trace(Pid, true): print every event this process handles"
            }
          >
            <span class="switch-track"><span class="switch-thumb"></span></span>
            <span class="mono">sys:trace</span>
          </button>
          <button
            :if={@kind in [:gen_server, :gen_statem]}
            type="button"
            class="secondary small-btn"
            phx-click="open_panel"
            phx-value-kind="state"
            title="sys:get_state(Pid), shown in a panel below"
          >
            State
          </button>
          <button
            :if={@kind == :supervisor}
            type="button"
            class="secondary small-btn"
            phx-click="open_panel"
            phx-value-kind="tree"
            title="The supervision tree under this supervisor, shown in a panel below"
          >
            Supervisor tree
          </button>
          <button class="secondary" phx-click="close_details" title="Close">×</button>
        </div>
      </div>

      <p :if={@sys_error} class="notice small">{@sys_error}</p>

      <p :if={@sys_traced} class="sys-on-note small">
        <span class="live-dot" aria-hidden="true"></span>
        sys:trace is on · its events are in the dock at the bottom
      </p>

      <BeamdashWeb.TriageGuide.box
        :if={@flag}
        flag={@flag}
        details={@details}
        kind={@kind}
        names={@names}
        syntax={@syntax}
      />

      <dl class="facts">
        <dt>Status</dt>
        <dd>{@details.status}</dd>
        <dt>Running</dt>
        <dd class="mono">{Format.mfa(@details.current_function, @syntax)}</dd>
        <dt>Priority</dt>
        <dd>{@details.priority}{if @details.trap_exit, do: " · traps exits"}</dd>
      </dl>

      <BeamdashWeb.ModuleInfo.section :if={@module_info} module={@module_info} syntax={@syntax} />

      <section>
        <h4>Reductions</h4>
        <div class="stat-row">
          <div class="stat">
            <span class="stat-value">{rate_text(@rate)}</span>
            <span class="stat-label">reductions / s now</span>
          </div>
          <div class="stat">
            <span class="stat-value">{Format.number(@details.reductions)}</span>
            <span class="stat-label">total since start</span>
          </div>
        </div>
        <.sparkline
          id="spark-reds"
          title="Reductions per second, last minute"
          points={for p <- @history, do: p.reds_per_sec}
          format={&rate_text/1}
        />
      </section>

      <section>
        <h4>Memory</h4>
        <div class="stat-row">
          <div class="stat">
            <span class="stat-value">{Format.bytes(@mem.total)}</span>
            <span class="stat-label">total</span>
          </div>
          <div class="stat">
            <span class="stat-value">{Format.bytes(@mem.binary_bytes)}</span>
            <span class="stat-label">
              in {Format.number(@mem.binary_count)} off-heap binar{if @mem.binary_count == 1,
                do: "y",
                else: "ies"}
            </span>
          </div>
        </div>
        <.sparkline
          id="spark-mem"
          title="Process memory, last minute"
          points={for p <- @history, do: p.memory}
          format={&Format.bytes/1}
        />
        <table class="kv">
          <tr>
            <th>Heap (young)</th><td>{Format.bytes(@mem.heap)}</td>
          </tr>
          <tr>
            <th>Old heap</th><td>{Format.bytes(@gc.old_heap_size)}</td>
          </tr>
          <tr>
            <th>Total heap</th><td>{Format.bytes(@mem.total_heap)}</td>
          </tr>
          <tr>
            <th>Stack</th><td>{Format.bytes(@mem.stack)}</td>
          </tr>
          <tr>
            <th>Heap fragments</th><td>{Format.bytes(@gc.mbuf_size)}</td>
          </tr>
          <tr>
            <th>Messages stored</th><td>{@mem.message_queue_data || "n/a"}</td>
          </tr>
        </table>
      </section>

      <section>
        <div class="section-head">
          <h4>Garbage collection</h4>
          <span class="panel-actions">
            <.link
              navigate={"/gc?pid=" <> Format.pid(@details.pid, :erlang)}
              class="btn-link small-btn"
              title="Open in the GC tab: generations, sweeps and GC trace"
            >
              GC ↗
            </.link>
            <button class="secondary small-btn" phx-click="gc">Force GC</button>
          </span>
        </div>
        <p :if={@gc_result} class="notice small">
          {gc_result_text(@gc_result)}
        </p>
        <table class="kv">
          <tr>
            <th>Minor GCs since last full sweep</th>
            <td>
              {Format.number(@gc.minor_gcs)} of {Format.number(@gc.fullsweep_after)}
            </td>
          </tr>
          <tr>
            <th>Heap block (allocated)</th><td>{Format.bytes(@gc.heap_block_size)}</td>
          </tr>
          <tr>
            <th>Live after last GC</th><td>{Format.bytes(@gc.recent_size)}</td>
          </tr>
          <tr>
            <th>Min heap size</th><td>{Format.bytes(@gc.min_heap_size)}</td>
          </tr>
          <tr>
            <th>Max heap size</th><td>{bytes_or(@gc.max_heap_size)}</td>
          </tr>
          <tr>
            <th>Binary vheap (young / old)</th>
            <td>{Format.bytes(@gc.bin_vheap_size)} / {Format.bytes(@gc.bin_old_vheap_size)}</td>
          </tr>
        </table>
      </section>

      <section>
        <h4>Mailbox · {Format.number(@mailbox.length)} message{if @mailbox.length != 1, do: "s"}</h4>
        <.sparkline
          :if={Enum.any?(@history, &(&1.message_queue_len > 0))}
          id="spark-mq"
          title="Message queue length, last minute"
          points={for p <- @history, do: p.message_queue_len}
          format={&Format.number/1}
        />
        <div :if={@mailbox.messages == :not_fetched} class="muted small">
          More than {Format.number(@mailbox.limit)} messages queued, so they are not fetched: reading a mailbox copies all of it, which adds load to a process that is already behind.
          <button
            :if={@mailbox.length <= 10_000}
            class="secondary small-btn"
            phx-click="fetch_messages"
          >
            Fetch anyway
          </button>
        </div>
        <p :if={@mailbox.messages == []} class="muted small">Empty.</p>
        <ol :if={is_list(@mailbox.messages) and @mailbox.messages != []} class="messages">
          <li :for={{id, m} <- message_ids(@mailbox.messages)}>
            <%!-- the panel refreshes every few seconds: keep a message the
                 user opened open, and on that message while earlier ones
                 are consumed --%>
            <details id={id} phx-mounted={JS.ignore_attributes(["open"])}>
              <summary class="mono">{Format.term(m, @syntax, 90)}</summary>
              <pre>{Format.pretty(m, @syntax)}</pre>
            </details>
          </li>
        </ol>
        <p
          :if={is_list(@mailbox.messages) and length(@mailbox.messages) < @mailbox.length}
          class="muted small"
        >
          Showing the first {length(@mailbox.messages)} of {Format.number(@mailbox.length)}, oldest first.
        </p>
      </section>

      <section :if={@details.current_stacktrace != []}>
        <h4>Current stack</h4>
        <pre class="small">{stack(@details.current_stacktrace, @syntax)}</pre>
      </section>

      <section>
        <h4>
          Links {length(@details.links)} · Monitors {length(@details.monitors)} · Monitored by {length(
            @details.monitored_by
          )}
        </h4>
        <%!-- links drawn as on the Applications tab: this process, its links to the right --%>
        <BeamdashWeb.AppChart.chart
          :if={@details.links != []}
          root={links_tree(@details, @names)}
          selected={@details.pid}
          syntax={@syntax}
          label="Linked processes"
          class="links-chart"
        />
        <dl :if={@details.monitors != [] or @details.monitored_by != []} class="relations">
          <%= for {title, items} <- [
                {"Monitors", Enum.map(@details.monitors, &monitored/1)},
                {"Monitored by", @details.monitored_by}
              ], items != [] do %>
            <dt>{title}</dt>
            <dd>
              <.proc_ref :for={item <- items} item={item} names={@names} syntax={@syntax} />
            </dd>
          <% end %>
        </dl>
      </section>

      <BeamdashWeb.JevSection.section
        :if={@jev}
        id="jev-process"
        event="analyze_process"
        title="Jev: next step"
        sends="Trends computed here (mailbox growth, memory change, reductions rate, shares), the process's status, OTP kind and rank on the node, and a short series of samples."
        enabled={@jev.enabled}
        configured={@jev.configured}
        busy={@jev.busy}
        readiness={@jev.readiness}
        advice={@jev.advice}
        error={@jev.error}
        evidence={@jev.evidence}
      />
    </aside>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :points, :list, required: true
  attr :format, :any, required: true

  attr :from_zero, :boolean,
    default: true,
    doc: "false: scale between the lowest and highest value, so small changes show"

  # One measure over the last minute: a 2px line, the latest value marked,
  # and a hover target per sample carrying its value.
  def sparkline(assigns) do
    values = assigns.points
    known = Enum.reject(values, &is_nil/1)
    {w, h, pad} = {300, 44, 5}
    max = Enum.max(known, fn -> 0 end)
    min = if assigns.from_zero, do: 0, else: Enum.min(known, fn -> 0 end)
    n = length(values)
    step = if n > 1, do: (w - 2 * pad) / (n - 1), else: 0
    span = max - min
    # a flat series sits in the middle when not drawn from zero
    y = fn v ->
      cond do
        span > 0 -> h - pad - (v - min) / span * (h - 2 * pad)
        assigns.from_zero -> h - pad
        true -> h / 2
      end
    end

    pts =
      for {v, i} <- Enum.with_index(values), v != nil, do: {pad + i * step, y.(v), v}

    assigns =
      assign(assigns,
        w: w,
        h: h,
        pts: pts,
        line:
          Enum.map_join(pts, " ", fn {x, yy, _} ->
            "#{Float.round(x * 1.0, 1)},#{Float.round(yy * 1.0, 1)}"
          end),
        last: List.last(pts),
        hit_w: max(step, 6),
        peak: max
      )

    ~H"""
    <figure class="spark" id={@id}>
      <%!-- Stretches to the panel's width: the drawing scales without
           keeping its aspect ratio, lines keep their stroke width
           (non-scaling-stroke) and the end dot is placed in HTML so it
           stays round. --%>
      <div class="spark-plot">
        <svg
          viewBox={"0 0 #{@w} #{@h}"}
          preserveAspectRatio="none"
          role="img"
          aria-label={@title}
        >
          <title>{@title}</title>
          <line
            class="spark-base"
            x1="0"
            x2={@w}
            y1={@h - 5}
            y2={@h - 5}
            vector-effect="non-scaling-stroke"
          />
          <polyline
            :if={length(@pts) > 1}
            class="spark-line"
            points={@line}
            vector-effect="non-scaling-stroke"
          />
          <rect
            :for={{x, _y, v} <- @pts}
            class="spark-hit"
            x={x - @hit_w / 2}
            y="0"
            width={@hit_w}
            height={@h}
          >
            <title>{@format.(v)}</title>
          </rect>
        </svg>
        <span
          :if={@last}
          class="spark-dot"
          style={"left: #{pct(elem(@last, 0), @w)}%; top: #{pct(elem(@last, 1), @h)}%"}
        ></span>
      </div>
      <figcaption class="muted small">
        {@title} · peak {@format.(@peak)}
      </figcaption>
    </figure>
    """
  end

  attr :item, :any, required: true
  attr :names, :map, required: true
  attr :syntax, :atom, required: true

  # A linked / monitoring process: a link that opens it here. Anything that
  # is not a local pid (a port, a process on another node, a name) is shown
  # as it is.
  defp proc_ref(%{item: pid} = assigns) when is_pid(pid) do
    assigns = assign(assigns, name: assigns.names[pid])

    ~H"""
    <button
      type="button"
      class="pid-link mono"
      phx-click="select"
      phx-value-pid={Format.pid(@item, :erlang)}
      title="Show this process"
    >
      <span :if={@name} class="pid-name">{Format.name(@name, @syntax)}</span>{Format.pid(
        @item,
        @syntax
      )}
    </button>
    """
  end

  defp proc_ref(assigns) do
    ~H"""
    <span class="mono small muted pid-other">{Format.term(@item, @syntax)}</span>
    """
  end

  @doc false
  # This process with its links as children, for BeamdashWeb.AppChart.
  # Ports and processes on other nodes are shown but cannot be opened.
  def links_tree(details, names) do
    here = node(details.pid)

    %{
      pid: details.pid,
      name: details[:registered_name],
      label: nil,
      static: true,
      also: [],
      children:
        for item <- details.links do
          %{
            pid: item,
            name: if(is_pid(item), do: names[item]),
            label: nil,
            static: not (is_pid(item) and node(item) == here),
            also: [],
            children: []
          }
        end
    }
  end

  # process_info(Pid, monitors): {process, Pid | {Name, Node}} | {port, ...}
  defp monitored({:process, pid}) when is_pid(pid), do: pid
  defp monitored({_type, other}), do: other
  defp monitored(other), do: other

  defp sys_kind?(kind), do: kind in @sys_kinds

  defp pct(v, total), do: Float.round(v / total * 100, 2)

  defp rate_text(nil), do: "…"
  defp rate_text(n), do: Format.number(n)

  defp bytes_or(:unlimited), do: "unlimited"
  defp bytes_or(n), do: Format.bytes(n)

  defp gc_result_text(%{before: b, after: a}) when b >= a,
    do: "Collected: #{Format.bytes(b)} → #{Format.bytes(a)} (freed #{Format.bytes(b - a)})."

  defp gc_result_text(%{before: b, after: a}),
    do: "Collected: #{Format.bytes(b)} → #{Format.bytes(a)}."

  defp stack(frames, syntax) do
    Enum.map_join(frames, "\n", fn
      {m, f, a, loc} ->
        where =
          case {loc[:file], loc[:line]} do
            {nil, _} -> ""
            {file, line} -> "  (#{file}:#{line})"
          end

        Format.mfa({m, f, a}, syntax) <> where

      other ->
        Format.term(other, syntax)
    end)
  end

  @doc false
  # A DOM id per queued message, stable while the queue moves: its content
  # hash plus which occurrence of that content it is.
  def message_ids(messages) do
    {ids, _seen} =
      Enum.map_reduce(messages, %{}, fn m, seen ->
        hash = :erlang.phash2(m)
        n = Map.get(seen, hash, 0)
        {{"mq-#{hash}-#{n}", m}, Map.put(seen, hash, n + 1)}
      end)

    ids
  end
end
