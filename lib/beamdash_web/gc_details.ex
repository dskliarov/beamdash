defmodule BeamdashWeb.GCDetails do
  @moduledoc """
  The GC tab's process panel: the same panel as on the Processes tab
  (resizable, live, with one-minute trends), showing what matters for
  garbage collection: heap generations, the minor-GC count against
  `fullsweep_after`, heap settings, binaries, a GC trace and the Jev
  advisor.
  """
  use Phoenix.Component

  alias Beamdash.Format
  alias BeamdashWeb.ProcessDetails

  @history 60

  @doc "Adds a detail sample to the panel's history (newest last)."
  def push(history, details) do
    point = %{
      memory: details.memory.total,
      heap_block: details.gc.heap_block_size,
      old_heap: details.gc.old_heap_size,
      recent: details.gc.recent_size
    }

    Enum.take(history ++ [point], -@history)
  end

  attr :details, :map, required: true
  attr :history, :list, required: true
  attr :syntax, :atom, required: true
  attr :kind, :atom, default: nil
  attr :gc_result, :map, default: nil
  attr :trace, :map, required: true, doc: "collector, events, status, seconds, started"
  attr :trace_durations, :list, required: true

  attr :jev, :map,
    required: true,
    doc: "%{enabled, configured, busy, readiness, advice, error, evidence}"

  def panel(assigns) do
    d = assigns.details

    assigns =
      assign(assigns,
        mem: d.memory,
        gc: d.gc,
        events: assigns.trace.events,
        recording: assigns.trace.collector != nil
      )

    ~H"""
    <aside class="proc-panel gc-panel" id="gc-details">
      <div
        id="gc-panel-resizer"
        class="resizer resizer-x"
        phx-hook="Resizer"
        phx-update="ignore"
        data-var="--panel-w"
        data-axis="x"
        data-target="#gc-details"
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
          <.link
            navigate={"/?pid=" <> Format.pid(@details.pid, :erlang)}
            class="btn-link small-btn"
            title="Open in the Processes tab: stack, mailbox, links, sys:trace"
          >
            Processes ↗
          </.link>
          <button class="secondary" phx-click="close_details" title="Close">×</button>
        </div>
      </div>

      <dl class="facts">
        <dt>Status</dt>
        <dd>{@details.status}</dd>
        <dt>Running</dt>
        <dd class="mono">{Format.mfa(@details.current_function, @syntax)}</dd>
        <dt>Mailbox</dt>
        <dd>
          {Format.number(@details.mailbox.length)} message{if @details.mailbox.length != 1, do: "s"}
          <span :if={@mem.message_queue_data} class="muted">· stored {@mem.message_queue_data}</span>
        </dd>
      </dl>

      <section>
        <h4>Heap</h4>
        <div class="stat-row">
          <div class="stat">
            <span class="stat-value">{Format.bytes(@mem.total)}</span>
            <span class="stat-label">process memory</span>
          </div>
          <div class="stat">
            <span class="stat-value">{bytes(@gc.old_heap_size)}</span>
            <span class="stat-label">old heap used</span>
          </div>
          <div class="stat">
            <span class="stat-value">{bytes(@gc.recent_size)}</span>
            <span class="stat-label">live after last GC</span>
          </div>
        </div>
        <ProcessDetails.sparkline
          id="gc-spark-mem"
          title="Process memory, last minute"
          points={for p <- @history, do: p.memory}
          format={&Format.bytes/1}
        />
        <ProcessDetails.sparkline
          id="gc-spark-old"
          title="Old heap used, last minute"
          points={for p <- @history, do: p.old_heap}
          format={&bytes/1}
        />
        <.generations gc={@gc} mem={@mem} />
        <table class="kv">
          <tr>
            <th>Young heap + stack allocated</th><td>{bytes(@gc.heap_block_size)}</td>
          </tr>
          <tr>
            <th>Old heap used / allocated</th>
            <td>{bytes(@gc.old_heap_size)} / {bytes(@gc.old_heap_block_size)}</td>
          </tr>
          <tr>
            <th>Stack</th><td>{bytes(@mem.stack)}</td>
          </tr>
          <tr>
            <th>Heap fragments</th><td>{bytes(@gc.mbuf_size)}</td>
          </tr>
        </table>
      </section>

      <section>
        <div class="section-head">
          <h4>Garbage collection</h4>
          <button
            class="secondary small-btn"
            phx-click="collect"
            id="gc-force-collect"
            title="Runs a full collection now; the process pauses while it collects"
          >
            Force GC
          </button>
        </div>
        <p :if={@gc_result} class="notice small" role="status">{gc_result_text(@gc_result)}</p>
        <.sweep_meter minor={@gc.minor_gcs} fullsweep={@gc.fullsweep_after} />
        <table class="kv">
          <tr>
            <th>Minimum heap</th><td>{bytes(@gc.min_heap_size)}</td>
          </tr>
          <tr>
            <th>Maximum heap</th><td>{bytes(@gc.max_heap_size)}</td>
          </tr>
          <tr>
            <th>Minimum binary virtual heap</th><td>{bytes(@gc.min_bin_vheap_size)}</td>
          </tr>
          <tr>
            <th>Binary vheap (young / old)</th>
            <td>{bytes(@gc.bin_vheap_size)} / {bytes(@gc.bin_old_vheap_size)}</td>
          </tr>
          <tr>
            <th>Referenced binaries</th>
            <td>
              {bytes(@mem.binary_bytes)}
              <span class="muted">· {Format.number(@mem.binary_count)}</span>
            </td>
          </tr>
        </table>
        <p class="muted small">
          Binaries are references, possibly shared with other processes; they live off the heap.
        </p>
      </section>

      <section id="gc-trace-output" aria-labelledby="gc-trace-title">
        <div class="section-head">
          <h4 id="gc-trace-title">GC trace</h4>
          <span role="status" class={["small", @recording && "gc-recording"]}>
            <span :if={@recording} class="live-dot" aria-hidden="true"></span>
            {if @recording,
              do: "Recording · up to #{@trace.seconds} s",
              else: @trace.status || "Not recording"}
          </span>
        </div>
        <form phx-change="trace_duration" phx-submit="trace" class="gc-trace-controls">
          <label for="gc-trace-duration" class="small muted">For</label>
          <select id="gc-trace-duration" name="duration" disabled={@recording}>
            <option
              :for={s <- @trace_durations}
              value={s}
              selected={@trace.seconds == s}
            >
              {s} s
            </option>
          </select>
          <button :if={!@recording} id="gc-trace-start" type="submit" class="small-btn">
            Trace GC
          </button>
          <button
            :if={@recording}
            id="gc-trace-stop"
            type="button"
            class="secondary small-btn"
            phx-click="stop"
          >
            Stop
          </button>
        </form>

        <div :if={@events != []} class="stat-row gc-trace-stats">
          <div class="stat">
            <span class="stat-value">{length(@events)}</span>
            <span class="stat-label">
              {Enum.count(@events, &(&1.kind == :minor))} minor · {Enum.count(
                @events,
                &(&1.kind == :major)
              )} full
            </span>
          </div>
          <div class="stat">
            <span class="stat-value">{us(Enum.sum(Enum.map(@events, & &1.duration_us)))}</span>
            <span class="stat-label">total GC time</span>
          </div>
          <div class="stat">
            <span class="stat-value">{us(Enum.max(Enum.map(@events, & &1.duration_us)))}</span>
            <span class="stat-label">longest</span>
          </div>
        </div>

        <p :if={@events == []} class="muted small gc-trace-empty" role="status">
          <%= cond do %>
            <% @recording -> %>
              Waiting for this process to collect. An idle process may not collect at all: exercise it, or press Force GC.
            <% @trace.started != nil -> %>
              No collections in this trace. An idle process may not collect: trace it during real work, or Force GC while recording.
            <% true -> %>
              Trace to see each minor collection and full sweep as it happens: how long it took and what it left.
          <% end %>
        </p>

        <div :if={@events != []} class="gc-trace-events" tabindex="0" aria-label="Recorded GC events">
          <table class="gc-events">
            <thead>
              <tr>
                <th>Newest first</th>
                <th class="num">Took</th>
                <th class="num">Heap before → after</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={e <- @events}>
                <td>
                  <span class={["gc-kind", e.kind == :major && "major"]}>
                    {if e.kind == :major, do: "full sweep", else: "minor"}
                  </span>
                </td>
                <td class="num">{us(e.duration_us)}</td>
                <td class="num">{Format.bytes(e.before)} → {Format.bytes(e.after)}</td>
              </tr>
            </tbody>
          </table>
        </div>
        <p class="muted small">
          Elapsed time between target timestamps, not CPU time; heap sizes exclude binaries. A trace stops after its time, 200 collections, overload or when you leave the page.
        </p>
      </section>

      <BeamdashWeb.JevSection.section
        id="jev-gc"
        event="analyze_gc"
        title={"#{Beamdash.Jev.name()}: next step"}
        sends="Heap, binary and mailbox trends computed here, the GC trace summary (rates, pause times, share of time in GC), the last Force GC result, OTP kind and rank on the node."
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

  attr :gc, :map, required: true
  attr :mem, :map, required: true

  # Young heap, old heap and stack as one bar, so it is clear at a glance
  # which generation holds the memory.
  defp generations(assigns) do
    parts =
      [
        {"young heap", num(assigns.mem.heap), "gen-young"},
        {"old heap", num(assigns.gc.old_heap_size), "gen-old"},
        {"stack", num(assigns.mem.stack), "gen-stack"}
      ]

    total = parts |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    assigns = assign(assigns, parts: parts, total: total)

    ~H"""
    <div :if={@total > 0} class="gen-bar" role="img" aria-label="Heap by generation">
      <span
        :for={{label, n, class} <- @parts}
        :if={n > 0}
        class={["gen-seg", class]}
        style={"flex-grow: #{n}"}
        title={"#{label}: #{Format.bytes(n)}"}
      ></span>
    </div>
    <div :if={@total > 0} class="gen-legend small">
      <span :for={{label, n, class} <- @parts}>
        <i class={["gen-swatch", class]}></i>{label} {Format.bytes(n)}
      </span>
    </div>
    """
  end

  attr :minor, :any, required: true
  attr :fullsweep, :any, required: true

  # Minor collections since the last full sweep, against fullsweep_after:
  # when they meet, the next collection is a full sweep.
  defp sweep_meter(assigns) do
    pct =
      if is_integer(assigns.minor) and is_integer(assigns.fullsweep) and assigns.fullsweep > 0,
        do: min(100, assigns.minor / assigns.fullsweep * 100),
        else: 0

    assigns = assign(assigns, pct: pct)

    ~H"""
    <div class="sweep-meter">
      <div class="sweep-label small">
        <span>Minor GCs since the last full sweep</span>
        <span class="mono">{Format.number(@minor)} of {Format.number(@fullsweep)}</span>
      </div>
      <div
        class="sweep-track"
        role="meter"
        aria-valuemin="0"
        aria-valuemax={@fullsweep}
        aria-valuenow={@minor}
        aria-label="Minor collections until a full sweep"
      >
        <span class="sweep-fill" style={"width: #{max(@pct, 1)}%"}></span>
      </div>
      <p class="muted small">
        At <span class="mono">fullsweep_after</span>, the next collection is a full sweep; old-heap pressure can force one sooner.
      </p>
    </div>
    """
  end

  defp num(n) when is_integer(n), do: n
  defp num(_), do: 0

  @doc false
  def bytes(n) when is_integer(n), do: Format.bytes(n)
  def bytes(:unlimited), do: "unlimited"
  def bytes(_), do: "n/a"

  defp us(n) when n >= 10_000, do: "#{Float.round(n / 1000, 1)} ms"
  defp us(n), do: "#{Format.number(n)} µs"

  defp gc_result_text(%{before: b, after: a}) when b >= a,
    do: "Collected: #{Format.bytes(b)} → #{Format.bytes(a)} (freed #{Format.bytes(b - a)})."

  defp gc_result_text(%{before: b, after: a}),
    do: "Collected: #{Format.bytes(b)} → #{Format.bytes(a)} (it grew meanwhile)."
end
