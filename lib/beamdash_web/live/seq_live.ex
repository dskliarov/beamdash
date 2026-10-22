defmodule BeamdashWeb.SeqLive do
  @moduledoc """
  seq_trace results: the messages caused by calls of seq-traced functions,
  as a sequence diagram (one lane per process) and a table.
  """
  use Phoenix.LiveView

  alias Beamdash.{Format, SeqAdvisor, SeqTracer, Target}

  @diagram_rows 80
  @max_lanes 8
  @row_h 34
  @top 64

  @impl true
  def mount(_params, _session, socket) do
    %{status: status, node: node} = Target.status()

    socket =
      assign(socket,
        status: status,
        node: node,
        events: [],
        traces: [],
        show_receives: false,
        selected: nil,
        # Jev: the pattern of the recorded messages
        pattern: %{request: nil, advice: nil, error: nil, evidence: nil}
      )

    if connected?(socket) do
      :ok = Target.subscribe()
      :ok = SeqTracer.subscribe()
      {:ok, assign(socket, events: SeqTracer.events(), traces: SeqTracer.traces())}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("stop", %{"mod" => m, "fun" => f, "arity" => a}, socket) do
    :ok =
      SeqTracer.stop(String.to_existing_atom(m), String.to_existing_atom(f), String.to_integer(a))

    {:noreply, assign(socket, traces: SeqTracer.traces())}
  end

  def handle_event("stop_all", _params, socket) do
    :ok = SeqTracer.stop_all()
    {:noreply, assign(socket, traces: SeqTracer.traces())}
  end

  def handle_event("clear", _params, socket) do
    :ok = SeqTracer.clear()
    {:noreply, socket |> assign(events: [], selected: nil) |> reset_pattern()}
  end

  def handle_event("analyze_seq", _params, %{assigns: %{pattern: %{request: nil}}} = socket) do
    if match?({:ready, _}, SeqAdvisor.readiness(socket.assigns.events)) do
      evidence = SeqAdvisor.evidence(socket.assigns.events)
      request = {:seq_advisor, make_ref()}

      {:noreply,
       socket
       |> assign(pattern: %{request: request, advice: nil, error: nil, evidence: evidence})
       |> start_async(request, fn -> SeqAdvisor.analyze(evidence) end)}
    else
      {:noreply,
       put_pattern(socket,
         error: "Record at least #{SeqAdvisor.min_messages()} messages first."
       )}
    end
  end

  def handle_event("analyze_seq", _params, socket), do: {:noreply, socket}

  def handle_event("receives", params, socket),
    do: {:noreply, assign(socket, show_receives: params["on"] == "true")}

  def handle_event("select", %{"id" => id}, socket) do
    id = String.to_integer(id)
    selected = if socket.assigns.selected == id, do: nil, else: id
    {:noreply, assign(socket, selected: selected)}
  end

  @impl true
  def handle_async({:seq_advisor, _} = request, result, socket) do
    if request == socket.assigns.pattern.request do
      socket = put_pattern(socket, request: nil)

      case result do
        {:ok, {:ok, advice}} -> {:noreply, put_pattern(socket, advice: advice)}
        {:ok, {:error, message}} -> {:noreply, put_pattern(socket, error: message)}
        {:exit, _} -> {:noreply, put_pattern(socket, error: "The analysis failed. Try again.")}
      end
    else
      {:noreply, socket}
    end
  end

  # Called by BeamdashWeb.Syntax when Jev is switched in Settings.
  def jev_changed(%{assigns: %{jev_enabled: true}} = socket), do: socket
  def jev_changed(socket), do: reset_pattern(socket)

  defp reset_pattern(socket) do
    socket = if r = socket.assigns.pattern.request, do: cancel_async(socket, r), else: socket
    assign(socket, pattern: %{request: nil, advice: nil, error: nil, evidence: nil})
  end

  defp put_pattern(socket, changes),
    do: assign(socket, pattern: Map.merge(socket.assigns.pattern, Map.new(changes)))

  @impl true
  def handle_info({:beamdash_seq, {:events, new}}, socket),
    do: {:noreply, update(socket, :events, &(&1 ++ new))}

  def handle_info({:beamdash_seq, :traces_changed}, socket),
    do: {:noreply, assign(socket, traces: SeqTracer.traces())}

  def handle_info({:beamdash_seq, :cleared}, socket),
    do: {:noreply, socket |> assign(events: [], selected: nil) |> reset_pattern()}

  def handle_info({:beamdash_target, {:connected, node}}, socket),
    do: {:noreply, assign(socket, status: :connected, node: node)}

  def handle_info({:beamdash_target, {:disconnected, _}}, socket),
    do: {:noreply, assign(socket, status: :disconnected, traces: [])}

  @impl true
  def render(assigns) do
    shown = Enum.filter(assigns.events, &(&1.type == :send or assigns.show_receives))
    assigns = assign(assigns, shown: shown, diagram: diagram(shown, assigns.syntax))

    ~H"""
    <main class="wrap">
      <BeamdashWeb.Layouts.header
        active={:seq}
        syntax={@syntax}
        conn={assigns[:conn]}
        ask={assigns[:ask]}
        ask_on={BeamdashWeb.JevSection.show?(assigns[:jev_enabled])}
      />

      <p :if={@status != :connected and @events == []} class="help">
        Not connected: enter a node above and click Connect.
      </p>

      <div class="active-traces">
        <strong>Seq tracing:</strong>
        <span :if={@traces == []} class="muted">
          nothing. Pick a function on the <.link navigate="/trace">Tracing</.link>
          page and choose “Seq trace”.
        </span>
        <span :for={{m, f, a} <- @traces} class="chip">
          {Format.mfa({m, f, a}, @syntax)}
          <a
            href="#"
            phx-click="stop"
            phx-value-mod={m}
            phx-value-fun={f}
            phx-value-arity={a}
            title="Stop"
          >
            ×
          </a>
        </span>
        <button
          :if={@traces != []}
          id="seq-stop-all"
          class="secondary"
          phx-click="stop_all"
          title="Stop seq tracing every function"
        >
          Stop all
        </button>
        <label class="small">
          <input
            type="checkbox"
            checked={@show_receives}
            phx-click="receives"
            phx-value-on={to_string(!@show_receives)}
          /> show receives
        </label>
        <button class="secondary" phx-click="clear">Clear</button>
      </div>

      <div :if={@events != [] and BeamdashWeb.JevSection.show?(@jev_enabled)} class="jev-card">
        <BeamdashWeb.JevSection.section
          id="jev-seq"
          event="analyze_seq"
          title="Jev: message-flow pattern"
          sends="The shape of the recorded messages, computed here: counts by kind (call, reply, cast), call-to-reply latency and unanswered calls, fan-out and fan-in, how much goes to or from one process, round trips, chain depth and burstiness."
          enabled={@jev_enabled}
          configured={Beamdash.Jev.configured?()}
          busy={@pattern.request != nil}
          readiness={seq_readiness(@events)}
          advice={@pattern.advice}
          error={@pattern.error}
          evidence={@pattern.evidence}
          basis={
            @pattern.advice &&
              "Based on #{@pattern.advice.samples} messages between #{@pattern.advice.processes} processes over #{@pattern.advice.window_s} s"
          }
        />
      </div>

      <p :if={@events == []} class="muted">
        No messages yet. Every call of a seq-traced function starts a trace token; the messages it sends, and the messages those cause, show up here.
      </p>

      <div :if={@diagram} class="seq-diagram">
        <p :if={@diagram.truncated} class="muted small">
          Diagram shows the latest {length(@diagram.rows)} messages; the table has all {length(@shown)}.
        </p>
        <svg
          width={@diagram.width}
          height={@diagram.height}
          viewBox={"0 0 #{@diagram.width} #{@diagram.height}"}
          role="img"
          aria-label="Sequence diagram of traced messages"
        >
          <defs>
            <marker
              id="seq-arrow"
              viewBox="0 0 10 10"
              refX="9"
              refY="5"
              markerWidth="7"
              markerHeight="7"
              orient="auto-start-reverse"
            >
              <path d="M0 0L10 5L0 10z" class="seq-arrowhead" />
            </marker>
          </defs>
          <g :for={lane <- @diagram.lanes}>
            <line class="seq-lifeline" x1={lane.x} x2={lane.x} y1="40" y2={@diagram.height - 8} />
            <text class="seq-lane" x={lane.x} y="24" text-anchor="middle">{lane.label}</text>
          </g>
          <g
            :for={row <- @diagram.rows}
            class={["seq-row", row.id == @selected && "selected", row.type != :send && "receive"]}
            phx-click="select"
            phx-value-id={row.id}
          >
            <rect class="seq-hit" x="0" y={row.y - 22} width={@diagram.width} height={@diagram.row_h} />
            <%= if row.x1 == row.x2 do %>
              <path
                class="seq-msg"
                d={"M#{row.x1} #{row.y - 6} h28 v12 h-28"}
                marker-end="url(#seq-arrow)"
              />
              <text class="seq-label" x={row.x1 + 34} y={row.y + 4}>{row.label}</text>
            <% else %>
              <line
                class="seq-msg"
                x1={row.x1}
                x2={row.x2}
                y1={row.y}
                y2={row.y}
                marker-end="url(#seq-arrow)"
              />
              <text class="seq-label" x={(row.x1 + row.x2) / 2} y={row.y - 6} text-anchor="middle">
                {row.label}
              </text>
            <% end %>
          </g>
        </svg>
      </div>

      <table :if={@shown != []} class="log seq-table">
        <thead>
          <tr>
            <th>Time (UTC)</th>
            <th>Type</th>
            <th>From</th>
            <th>To</th>
            <th>Message</th>
          </tr>
        </thead>
        <tbody>
          <%= for e <- @shown do %>
            <tr
              class={["clickable", e.id == @selected && "selected"]}
              phx-click="select"
              phx-value-id={e.id}
            >
              <td class="mono">{Format.time(e.timestamp_us)}</td>
              <td>{e.type}</td>
              <td class="mono">{e.from}</td>
              <td class="mono">{e.to}</td>
              <td class="mono">{Format.term(e.message, @syntax)}</td>
            </tr>
            <tr :if={e.id == @selected} class="expanded">
              <td colspan="5"><pre><%= Format.pretty(e.message, @syntax) %></pre></td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </main>
    """
  end

  # Lanes in order of first appearance; more than @max_lanes processes
  # share a final "other" lane.
  defp diagram([], _syntax), do: nil

  defp diagram(events, syntax) do
    rows = Enum.take(events, -@diagram_rows)

    names =
      rows
      |> Enum.flat_map(&[&1.from, &1.to])
      |> Enum.uniq()

    {named, rest} = Enum.split(names, @max_lanes)
    lane_names = if rest == [], do: named, else: named ++ ["other"]
    lane_of = fn name -> if name in named, do: name, else: "other" end

    width = max(960, 190 * length(lane_names))
    gap = width / length(lane_names)
    x = Map.new(Enum.with_index(lane_names), fn {n, i} -> {n, round(gap * i + gap / 2)} end)

    lanes = Enum.map(lane_names, &%{x: x[&1], label: short(&1)})

    diagram_rows =
      rows
      |> Enum.with_index()
      |> Enum.map(fn {e, i} ->
        %{
          id: e.id,
          type: e.type,
          x1: x[lane_of.(e.from)],
          x2: x[lane_of.(e.to)],
          y: @top + i * @row_h,
          label: Format.term(e.message, syntax, 44)
        }
      end)

    %{
      lanes: lanes,
      rows: diagram_rows,
      width: width,
      row_h: @row_h,
      height: @top + length(rows) * @row_h,
      truncated: length(events) > length(rows)
    }
  end

  defp short("alias " <> _), do: "(reply alias)"
  defp short(name) when byte_size(name) > 22, do: String.slice(name, 0, 21) <> "…"
  defp short(name), do: name

  # JevSection shows {:collecting, have, need}; here they are messages
  defp seq_readiness(events), do: SeqAdvisor.readiness(events)
end
