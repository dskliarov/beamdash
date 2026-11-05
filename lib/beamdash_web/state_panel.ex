defmodule BeamdashWeb.StatePanel do
  @moduledoc """
  A dock panel with the state of a gen_server or gen_statem
  (`sys:get_state/2` through `Beamdash.OtpProcess`), refreshed on request.
  Records are shown with their field names when the callback module has
  debug info; a gen_statem's `{State, Data}` is shown as both.
  """
  use Phoenix.LiveComponent

  alias Beamdash.{Format, OtpProcess}
  alias BeamdashWeb.TermTree
  alias Phoenix.LiveView.JS

  @impl true
  def mount(socket), do: {:ok, assign(socket, result: nil, loading: false, pid: nil, view: :text)}

  @impl true
  def update(assigns, socket) do
    first? = socket.assigns.pid == nil
    socket = assign(socket, assigns)
    {:ok, if(first?, do: fetch(socket), else: socket)}
  end

  defp fetch(socket) do
    pid = socket.assigns.pid

    socket
    |> assign(loading: true)
    |> start_async(:fetch, fn -> OtpProcess.state(pid) end)
  end

  @impl true
  def handle_async(:fetch, {:ok, result}, socket),
    do: {:noreply, assign(socket, result: result, loading: false)}

  def handle_async(:fetch, {:exit, reason}, socket),
    do: {:noreply, assign(socket, result: {:error, reason}, loading: false)}

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, fetch(socket)}

  def handle_event("set_view", %{"view" => view}, socket),
    do: {:noreply, assign(socket, view: if(view == "tree", do: :tree, else: :text))}

  @impl true
  def render(assigns) do
    ~H"""
    <article
      id={"state-panel-#{@key}"}
      class={["sys-panel", "kind-state", if(@active, do: "active", else: "minimized")]}
      aria-label={"State of #{@label}"}
    >
      <header class="sys-panel-head">
        <button
          type="button"
          class="sys-panel-toggle"
          phx-click="dock_activate"
          phx-value-kind="state"
          phx-value-pid={Format.pid(@pid, :erlang)}
          aria-expanded={to_string(@active)}
          disabled={@active}
          title={if @active, do: "Shown", else: "Show #{@label}'s state"}
        >
          <span class="sys-panel-chevron" aria-hidden="true">{if @active, do: "▾", else: "▸"}</span>
          <span class="panel-kind">State</span>
          <span class="sys-panel-name mono">{@label}</span>
          <span class="muted small">{summary(@result, @loading)}</span>
        </button>
        <span class="sys-panel-actions">
          <button
            class="secondary small-btn"
            phx-click="refresh"
            phx-target={@myself}
            disabled={@loading}
            title="sys:get_state(Pid) again"
          >
            {if @loading, do: "Reading…", else: "Refresh"}
          </button>
          <button
            class="secondary small-btn"
            phx-click="select"
            phx-value-pid={Format.pid(@pid, :erlang)}
          >
            Details
          </button>
          <button
            class="secondary small-btn"
            phx-click="dock_close"
            phx-value-kind="state"
            phx-value-pid={Format.pid(@pid, :erlang)}
            aria-label={"Close the state of #{@label}"}
          >
            ×
          </button>
        </span>
      </header>
      <div class="sys-panel-body" hidden={!@active}>
        <div class="state-body">
          <%= case @result do %>
            <% nil -> %>
              <p class="muted small">Reading the state…</p>
            <% {:ok, %{state: state} = r} -> %>
              <p class="muted small">
                <span class="mono">sys:get_state({Format.pid(@pid, @syntax)})</span>
                <span :if={r.module}> · {Format.name(r.module, @syntax)}</span>
                · read {Calendar.strftime(r.at, "%H:%M:%S")} UTC
              </p>
              <nav class="seg state-view" role="tablist" aria-label="Output format">
                <button
                  :for={{view, label} <- [text: "Text", tree: "Tree"]}
                  type="button"
                  role="tab"
                  class={["seg-btn", @view == view && "active"]}
                  aria-selected={to_string(@view == view)}
                  phx-click="set_view"
                  phx-value-view={view}
                  phx-target={@myself}
                >
                  {label}
                </button>
              </nav>
              <span :if={@view == :tree} class="tree-actions">
                <button
                  type="button"
                  class="secondary small-btn"
                  phx-click={
                    JS.set_attribute({"open", ""}, to: "#state-panel-#{@key} .state-tree details")
                  }
                >
                  Expand all
                </button>
                <button
                  type="button"
                  class="secondary small-btn"
                  phx-click={
                    JS.remove_attribute("open", to: "#state-panel-#{@key} .state-tree details")
                  }
                >
                  Collapse all
                </button>
              </span>
              <%= if @proc_kind == :gen_statem and match?({_, _}, state) do %>
                <p class="statem-state">
                  State <span class="mono state-name">{Format.term(elem(state, 0), @syntax)}</span>
                </p>
                <h5>Data</h5>
                <.state_value value={elem(state, 1)} view={@view} syntax={@syntax} />
              <% else %>
                <.state_value value={state} view={@view} syntax={@syntax} />
              <% end %>
            <% {:error, reason} -> %>
              <p class="notice small">{error_text(reason)}</p>
          <% end %>
        </div>
      </div>
    </article>
    """
  end

  attr :value, :any, required: true
  attr :view, :atom, required: true
  attr :syntax, :atom, required: true

  defp state_value(%{view: :tree} = assigns) do
    ~H"""
    <div class="state-tree"><TermTree.tree value={@value} syntax={@syntax} /></div>
    """
  end

  defp state_value(assigns) do
    ~H"""
    <pre class="state-pre">{Format.pretty(@value, @syntax)}</pre>
    """
  end

  defp summary(_result, true), do: "reading…"
  defp summary({:ok, r}, _), do: "read #{Calendar.strftime(r.at, "%H:%M:%S")} UTC"
  defp summary({:error, _}, _), do: "could not read"
  defp summary(nil, _), do: ""

  defp error_text(:timeout),
    do:
      "The process did not answer within 3 s: it is busy (or blocked), so it cannot reply to sys:get_state now."

  defp error_text(:noproc), do: "The process has exited."
  defp error_text(:not_connected), do: "Not connected."
  defp error_text(reason), do: "sys:get_state failed: #{Format.error(reason)}"
end
