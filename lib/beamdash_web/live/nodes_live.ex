defmodule BeamdashWeb.NodesLive do
  @moduledoc """
  The attached node's cluster: the node itself and the nodes it is
  connected to (`nodes()`; with Show hidden also its hidden connections,
  beamdash's own left out). Refreshed every 5 s. Clicking another node
  moves the connection there (`Beamdash.Target.switch/2`): with the cookie
  the attached node uses for it, or through a tunnel to its pod when
  attached through kubectl.

  `/nodes?switch=<node>` does the same from a link elsewhere (a plugin's
  node names, `Beamdash.Plugin.switch_path/2`), also to a hidden node;
  with `&return=<path>` the page goes back there once connected.
  """
  use Phoenix.LiveView

  alias Beamdash.{Format, Target}

  @refresh_ms 5_000

  @impl true
  def mount(_params, session, socket) do
    target = session["target"] || Target
    %{status: status, node: node} = Target.status(target)

    socket =
      assign(socket,
        target: target,
        status: status,
        node: node,
        nodes: nil,
        show_hidden: false,
        switching: nil,
        return_to: nil,
        note: nil,
        error: nil
      )

    if connected?(socket) do
      :ok = Target.subscribe(target)
      Process.send_after(self(), :refresh, @refresh_ms)
      {:ok, load(socket)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_params(%{"switch" => name} = params, _uri, socket) do
    socket = assign(socket, return_to: return_path(params["return"]))
    nodes = socket.assigns.nodes

    cond do
      not connected?(socket) -> {:noreply, socket}
      name == to_string(socket.assigns.node) -> {:noreply, done(socket, socket.assigns.node)}
      nodes == nil -> {:noreply, switch(socket, name, [])}
      true -> {:noreply, switch(socket, name, nodes.visible ++ nodes.hidden)}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # a path in beamdash only
  defp return_path("/" <> rest = path) do
    if String.starts_with?(rest, ["/", "\\"]), do: nil, else: path
  end

  defp return_path(_), do: nil

  defp load(%{assigns: %{status: :connected}} = socket) do
    case Target.cluster_nodes(socket.assigns.target) do
      {:ok, nodes} -> assign(socket, nodes: nodes, error: nil)
      {:error, reason} -> assign(socket, error: Format.error(reason))
    end
  end

  defp load(socket), do: socket

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  def handle_event("toggle_hidden", _params, socket),
    do: {:noreply, assign(socket, show_hidden: not socket.assigns.show_hidden)}

  def handle_event("switch", %{"node" => name}, %{assigns: %{switching: nil}} = socket) do
    if Enum.any?(listed(socket.assigns), &(Atom.to_string(&1) == name)),
      do: {:noreply, socket |> assign(return_to: nil) |> switch(name, listed(socket.assigns))},
      else: {:noreply, socket}
  end

  def handle_event("switch", _params, socket), do: {:noreply, socket}

  # only one of `nodes`: the name is never made into an atom
  defp switch(socket, name, nodes) do
    case Enum.find(nodes, &(Atom.to_string(&1) == name)) do
      nil ->
        error =
          if socket.assigns.node,
            do: "#{name} is not connected to #{socket.assigns.node}.",
            else: "Not connected."

        assign(socket, error: error)

      node ->
        target = socket.assigns.target

        socket
        |> assign(switching: node, note: nil, error: nil)
        |> start_async(:switch, fn -> Target.switch(node, target) end)
    end
  end

  defp done(%{assigns: %{return_to: path}} = socket, _node) when is_binary(path),
    do: push_navigate(socket, to: path)

  defp done(socket, node),
    do: socket |> assign(note: "Connected to #{node}.") |> push_patch(to: "/nodes")

  @impl true
  def handle_async(:switch, {:ok, {:ok, _info}}, socket),
    do: {:noreply, socket |> assign(switching: nil) |> done(socket.assigns.switching)}

  def handle_async(:switch, {:ok, {:error, reason}}, socket),
    do: {:noreply, switch_failed(socket, Format.error(reason))}

  def handle_async(:switch, {:exit, reason}, socket),
    do: {:noreply, switch_failed(socket, Format.error(reason))}

  defp switch_failed(socket, text) do
    assign(socket,
      switching: nil,
      error: "Could not connect to #{socket.assigns.switching}: #{text}"
    )
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, load(socket)}
  end

  def handle_info({:beamdash_target, {:connected, node}}, socket),
    do: {:noreply, socket |> assign(status: :connected, node: node) |> load()}

  def handle_info({:beamdash_target, {:disconnected, _}}, socket),
    do: {:noreply, assign(socket, status: :disconnected, node: nil, nodes: nil)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # the nodes shown, other than the attached one
  defp listed(%{nodes: nil}), do: []
  defp listed(%{nodes: n, show_hidden: true}), do: n.visible ++ n.hidden
  defp listed(%{nodes: n}), do: n.visible

  ## Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <main class="wrap nodes-page">
      <BeamdashWeb.Layouts.header
        active={:nodes}
        syntax={@syntax}
        conn={assigns[:conn]}
        ask={assigns[:ask]}
        ask_on={BeamdashWeb.JevSection.show?(assigns[:jev_enabled])}
      />

      <p :if={@status != :connected} class="help">
        Not connected: enter a node above and click Connect.
      </p>
      <p :if={@switching} class="muted" role="status">Connecting to {@switching}…</p>
      <p :if={@note} class="muted" role="status">{@note}</p>
      <p :if={@error} class="error" role="alert">{@error}</p>

      <%= if @status == :connected and @nodes do %>
        <div class="sys-head">
          <span class="muted small">
            The nodes {@nodes.this} is connected to · every 5 s
          </span>
          <label class="small">
            <input type="checkbox" checked={@show_hidden} phx-click="toggle_hidden" /> Show hidden
          </label>
          <button class="secondary small-btn" phx-click="refresh">Refresh</button>
        </div>

        <table class="nodes-table">
          <thead>
            <tr>
              <th>Node</th>
              <th>Connection</th>
              <th><span class="sr-only">Action</span></th>
            </tr>
          </thead>
          <tbody>
            <tr class="current">
              <td class="mono"><strong>{@nodes.this}</strong></td>
              <td>attached</td>
              <td></td>
            </tr>
            <tr :for={{node, kind} <- rows(assigns)}>
              <td class="mono">
                <button
                  type="button"
                  class="node-link"
                  phx-click="switch"
                  phx-value-node={node}
                  disabled={@switching != nil}
                  title={"Connect to #{node}"}
                >
                  {node}
                </button>
              </td>
              <td>{kind}</td>
              <td>
                <span :if={@switching == node} class="muted small">Connecting…</span>
              </td>
            </tr>
          </tbody>
        </table>
        <p :if={rows(assigns) == []} class="muted">
          {@nodes.this} is not connected to {if @show_hidden,
            do: "any other node",
            else: "any visible node"}.
        </p>
        <p :if={rows(assigns) != []} class="muted small">
          Click a node to connect to it instead, with the cookie {@nodes.this} uses for it.
        </p>
      <% end %>
    </main>
    """
  end

  defp rows(assigns) do
    Enum.map(assigns.nodes.visible, &{&1, "visible"}) ++
      if(assigns.show_hidden, do: Enum.map(assigns.nodes.hidden, &{&1, "hidden"}), else: [])
  end
end
