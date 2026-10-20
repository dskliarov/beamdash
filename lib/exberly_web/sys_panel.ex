defmodule ExberlyWeb.SysPanel do
  @moduledoc """
  One sys:trace panel in the dock: the live events of one traced process,
  newest first, with Clear and Stop.

  Only one panel in the dock is active: it is maximized and fills the dock;
  the others are minimized to their header, keep collecting events and
  count the ones not seen yet. Clicking a minimized panel's header makes it
  the active one (the page keeps track of which is active).

  The events are a LiveView stream owned by this component, so every panel
  keeps its own list. The page (`ExberlyWeb.HomeLive`) passes on what
  `Exberly.SysTracer` reports with `send_update/2`:

    * `new_events: [event]` – prepend them
    * `dropped: n` – n more events were dropped
    * `reload: true` – reload from SysTracer (after Clear)
  """
  use Phoenix.LiveComponent

  alias Exberly.{Format, SysEvent, SysTracer}
  alias Phoenix.LiveView.JS

  @max_events 300

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(count: 0, unseen: 0, dropped: 0, exited: nil, active: false, loaded_syntax: nil)
     |> stream(:events, [], limit: @max_events)}
  end

  @impl true
  def update(%{new_events: evs}, socket) do
    socket =
      Enum.reduce(evs, socket, fn ev, sock ->
        stream_insert(sock, :events, ev, at: 0, limit: @max_events)
      end)

    exited =
      Enum.find_value(evs, socket.assigns.exited, fn
        %{event: {:exberly_exited, reason}} -> reason
        _ -> nil
      end)

    unseen = if socket.assigns.active, do: 0, else: socket.assigns.unseen + length(evs)

    {:ok,
     assign(socket,
       count: min(socket.assigns.count + length(evs), @max_events),
       unseen: min(unseen, @max_events),
       exited: exited
     )}
  end

  def update(%{dropped: n}, socket),
    do: {:ok, assign(socket, dropped: socket.assigns.dropped + n)}

  def update(%{reload: true}, socket), do: {:ok, reload(socket)}

  # From the page's render: pid, label, key (for DOM ids), syntax and
  # active. The stream is filled the first time, and rebuilt when the
  # syntax changes (streamed rows are not re-rendered otherwise). Becoming
  # active marks everything seen.
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    socket = if socket.assigns.active, do: assign(socket, unseen: 0), else: socket

    if socket.assigns.loaded_syntax != socket.assigns.syntax,
      do: {:ok, reload(socket)},
      else: {:ok, socket}
  end

  defp reload(socket) do
    case SysTracer.info(socket.assigns.pid) do
      nil ->
        assign(socket, loaded_syntax: socket.assigns.syntax)

      %{events: events, dropped: dropped, exited: exited} ->
        newest_first = events |> Enum.reverse() |> Enum.take(@max_events)

        socket
        |> stream(:events, newest_first, reset: true, limit: @max_events)
        |> assign(
          count: length(newest_first),
          dropped: dropped,
          exited: exited,
          loaded_syntax: socket.assigns.syntax
        )
    end
  end

  @impl true
  def handle_event("clear", _params, socket) do
    :ok = SysTracer.clear(socket.assigns.pid)
    {:noreply, socket}
  end

  def handle_event("stop", _params, socket) do
    # The page hears :disabled from SysTracer and drops this panel.
    _ = SysTracer.disable(socket.assigns.pid)
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <article
      id={"sys-panel-#{@key}"}
      class={["sys-panel", if(@active, do: "active", else: "minimized")]}
      aria-label={"sys:trace of #{@label}"}
    >
      <header class="sys-panel-head">
        <%!-- the whole header activates a minimized panel; this button is
             its keyboard-reachable part --%>
        <button
          type="button"
          class="sys-panel-toggle"
          phx-click="dock_activate"
          phx-value-kind="trace"
          phx-value-pid={Format.pid(@pid, :erlang)}
          aria-expanded={to_string(@active)}
          aria-controls={"sys-panel-body-#{@key}"}
          title={if @active, do: "Shown", else: "Show #{@label}'s events"}
          disabled={@active}
        >
          <span class="sys-panel-chevron" aria-hidden="true">{if @active, do: "▾", else: "▸"}</span>
          <span class="live-dot" aria-hidden="true"></span>
          <span class="sys-panel-name mono">{@label}</span>
          <span class="muted small">
            {Format.number(@count)} event{if @count != 1, do: "s"}
          </span>
          <span :if={@unseen > 0} class="sys-panel-unseen" title="New since you last looked">
            {Format.number(@unseen)} new
          </span>
          <span :if={@dropped > 0} class="muted small">
            · {Format.number(@dropped)} dropped (over 1,000/s)
          </span>
          <span :if={@exited != nil} class="error small">
            · exited: {Format.term(@exited, @syntax, 60)}
          </span>
        </button>
        <span class="sys-panel-actions">
          <button
            class="secondary small-btn"
            phx-click="select"
            phx-value-pid={Format.pid(@pid, :erlang)}
            title={"Open #{Format.pid(@pid, @syntax)} in the process panel"}
          >
            Details
          </button>
          <button class="secondary small-btn" phx-click="clear" phx-target={@myself}>
            Clear
          </button>
          <button
            class="secondary small-btn"
            phx-click="stop"
            phx-target={@myself}
            title={"sys:trace(#{Format.pid(@pid, :erlang)}, false)"}
            aria-label={"Stop tracing #{@label}"}
          >
            Stop
          </button>
        </span>
      </header>

      <%!-- hidden rather than removed when minimized: streamed rows are not
           kept on the server, so a re-rendered list would come back empty --%>
      <div class="sys-panel-body" id={"sys-panel-body-#{@key}"} hidden={!@active}>
        <p :if={@count == 0} class="muted small sys-panel-empty">
          Waiting for events: each call, cast, message and reply {@label} handles shows here.
        </p>
        <ol id={"sys-events-#{@key}"} class="sys-events" phx-update="stream">
          <li :for={{dom_id, ev} <- @streams.events} id={dom_id}>
            <% {tag, text} = SysEvent.describe(ev.event, @syntax) %>
            <%!-- stays open while new events are patched in --%>
            <details phx-mounted={JS.ignore_attributes(["open"])}>
              <summary>
                <span class="ev-time mono muted">{Format.time(ev.at_us)}</span>
                <span class={["ev-tag", "ev-#{tag}"]}>{tag}</span>
                <span class="ev-text mono">{text}</span>
              </summary>
              <pre>{Format.pretty(ev.event, @syntax)}</pre>
            </details>
          </li>
        </ol>
      </div>
    </article>
    """
  end
end
