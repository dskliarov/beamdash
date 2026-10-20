defmodule ExberlyWeb.TreePanel do
  @moduledoc """
  A dock panel with the supervision tree under a supervisor
  (`Exberly.OtpProcess.tree/1`): every child with its id, kind, name,
  memory and mailbox; supervisors expand (the first levels start open).
  Clicking a process opens it in the process panel.
  """
  use Phoenix.LiveComponent

  alias Exberly.{Format, OtpProcess}
  alias ExberlyWeb.Icons

  @impl true
  def mount(socket), do: {:ok, assign(socket, result: nil, loading: false, pid: nil)}

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
    |> start_async(:fetch, fn -> OtpProcess.tree(pid) end)
  end

  @impl true
  def handle_async(:fetch, {:ok, result}, socket),
    do: {:noreply, assign(socket, result: result, loading: false)}

  def handle_async(:fetch, {:exit, reason}, socket),
    do: {:noreply, assign(socket, result: {:error, reason}, loading: false)}

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, fetch(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <article
      id={"tree-panel-#{@key}"}
      class={["sys-panel", "kind-tree", if(@active, do: "active", else: "minimized")]}
      aria-label={"Supervision tree of #{@label}"}
    >
      <header class="sys-panel-head">
        <button
          type="button"
          class="sys-panel-toggle"
          phx-click="dock_activate"
          phx-value-kind="tree"
          phx-value-pid={Format.pid(@pid, :erlang)}
          aria-expanded={to_string(@active)}
          disabled={@active}
          title={if @active, do: "Shown", else: "Show the tree under #{@label}"}
        >
          <span class="sys-panel-chevron" aria-hidden="true">{if @active, do: "▾", else: "▸"}</span>
          <span class="panel-kind">Supervisor tree</span>
          <span class="sys-panel-name mono">{@label}</span>
          <span class="muted small">{summary(@result, @loading)}</span>
        </button>
        <span class="sys-panel-actions">
          <button
            class="secondary small-btn"
            phx-click="refresh"
            phx-target={@myself}
            disabled={@loading}
          >
            {if @loading, do: "Reading…", else: "Refresh"}
          </button>
          <button
            class="secondary small-btn"
            phx-click="dock_close"
            phx-value-kind="tree"
            phx-value-pid={Format.pid(@pid, :erlang)}
            aria-label={"Close the tree of #{@label}"}
          >
            ×
          </button>
        </span>
      </header>
      <div class="sys-panel-body" hidden={!@active}>
        <div class="tree-body">
          <%= case @result do %>
            <% nil -> %>
              <p class="muted small">Reading the tree…</p>
            <% {:ok, tree} -> %>
              <ul class="sup-tree" role="tree">
                <.tree_node node={tree} level={0} syntax={@syntax} />
              </ul>
            <% {:error, reason} -> %>
              <p class="notice small">Could not read the tree: {Format.error(reason)}</p>
          <% end %>
        </div>
      </div>
    </article>
    """
  end

  attr :node, :map, required: true
  attr :level, :integer, required: true
  attr :syntax, :atom, required: true

  defp tree_node(assigns) do
    assigns =
      assign(assigns,
        kids: if(is_list(assigns.node.children), do: assigns.node.children, else: []),
        running: is_pid(assigns.node.pid)
      )

    ~H"""
    <li role="treeitem" aria-expanded={@kids != [] && to_string(@level < 2)}>
      <%= if @kids != [] do %>
        <details open={@level < 2}>
          <summary>
            <.row node={@node} running={@running} syntax={@syntax} count={length(@kids)} />
          </summary>
          <ul role="group">
            <.tree_node :for={k <- @kids} node={k} level={@level + 1} syntax={@syntax} />
          </ul>
        </details>
      <% else %>
        <div class="leaf"><.row node={@node} running={@running} syntax={@syntax} count={nil} /></div>
        <p :if={@node.children == :more} class="muted small tree-note">… deeper levels not read</p>
        <p :if={match?({:error, _}, @node.children)} class="muted small tree-note">
          children not available: {Format.term(elem(@node.children, 1), @syntax, 80)}
        </p>
      <% end %>
    </li>
    """
  end

  attr :node, :map, required: true
  attr :running, :boolean, required: true
  attr :count, :any, required: true
  attr :syntax, :atom, required: true

  defp row(assigns) do
    ~H"""
    <span class={["tree-row", !@running && "not-running"]}>
      <span class="tree-icon">
        <Icons.kind :if={@node.kind in Icons.marked_kinds()} kind={@node.kind} />
        <span :if={@node.kind not in Icons.marked_kinds()} class="worker-dot" aria-hidden="true"></span>
      </span>
      <span class="tree-id mono">{id_text(@node.id, @syntax)}</span>
      <button
        :if={@running}
        type="button"
        class="tree-proc mono"
        phx-click="select"
        phx-value-pid={Format.pid(@node.pid, :erlang)}
        onclick="event.preventDefault()"
        title="Open in the process panel"
      >
        {if @node.name, do: Format.name(@node.name, @syntax) <> " ", else: ""}{Format.pid(
          @node.pid,
          @syntax
        )}
      </button>
      <span :if={!@running} class="muted small">{not_running_text(@node.pid)}</span>
      <span :if={@node[:strategy]} class="tree-badge">{@node.strategy}</span>
      <span :if={@count} class="muted small">{@count} child{if @count != 1, do: "ren"}</span>
      <span :if={@running} class="muted small tree-mem">{Format.bytes(@node.memory)}</span>
      <span :if={@node.message_queue_len > 0} class="tree-queue" title="Messages waiting">
        {Format.number(@node.message_queue_len)} queued
      </span>
    </span>
    """
  end

  defp id_text(:root, _syntax), do: "root"
  defp id_text(:undefined, _syntax), do: "(dynamic)"
  defp id_text(id, syntax), do: Format.term(id, syntax, 60)

  defp not_running_text(:restarting), do: "restarting"
  defp not_running_text(_), do: "not running"

  defp summary(_r, true), do: "reading…"

  defp summary({:ok, tree}, _) do
    c = OtpProcess.counts(tree)

    "#{c.supervisors} supervisor#{if c.supervisors != 1, do: "s"} · #{c.workers} worker#{if c.workers != 1, do: "s"}" <>
      if(c.not_running > 0, do: " · #{c.not_running} not running", else: "")
  end

  defp summary({:error, _}, _), do: "could not read"
  defp summary(nil, _), do: ""
end
