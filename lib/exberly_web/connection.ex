defmodule ExberlyWeb.Connection do
  @moduledoc """
  `on_mount` hook that gives every page the connection bar
  (`ExberlyWeb.Layouts.header/1`): `@conn` holds the status, node, node
  info (OTP release, process count, memory, refreshed every 2 s), the node
  and cookie to offer in the form and a connection error. It handles the bar's `connect`
  and `disconnect` events on any tab.

  Connection events still reach the page: the hook updates `@conn` and
  lets `{:exberly_target, _}` messages continue to the page's own
  `handle_info/2`.

  The form starts with the last node and cookie that connected
  (`Exberly.LastConnection`, kept across restarts); a node typed in this
  session that failed to connect is offered instead until one succeeds.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias Exberly.{Format, LastConnection, Target}

  @refresh_ms 2_000
  @last_node {__MODULE__, :last_node}

  def on_mount(:default, _params, _session, socket) do
    %{status: status, node: node} = Target.status()
    saved = LastConnection.get()

    socket =
      socket
      |> assign(:conn, %{
        status: status,
        node: node,
        info: nil,
        node_input: if(node, do: Atom.to_string(node), else: last_node(saved.node)),
        cookie_input: saved.cookie,
        error: nil
      })
      |> attach_hook(:conn_event, :handle_event, &handle_event/3)
      |> attach_hook(:conn_info, :handle_info, &handle_info/2)

    if connected?(socket) do
      :ok = Target.subscribe()
      send(self(), :exberly_conn_tick)
    end

    {:cont, socket}
  end

  @doc false
  def handle_event("connect", %{"node" => node} = params, socket) do
    node = String.trim(node)
    :persistent_term.put(@last_node, node)
    cookie = params |> Map.get("cookie", "") |> String.trim()

    case Target.connect(node, if(cookie == "", do: nil, else: cookie)) do
      {:ok, info} ->
        # remembered for the form, also after a restart
        LastConnection.put(node, if(cookie == "", do: nil, else: cookie))
        :persistent_term.erase(@last_node)

        # the page hears {:connected, node} from Target as well
        {:halt,
         update(socket,
           status: :connected,
           node: info.node,
           info: info,
           error: nil,
           cookie_input: cookie
         )}

      {:error, reason} ->
        {:halt,
         update(socket, error: Format.error(reason), node_input: node, cookie_input: cookie)}
    end
  end

  def handle_event("disconnect", _params, socket) do
    :ok = Target.disconnect()
    {:halt, update(socket, status: :disconnected, node: nil, info: nil)}
  end

  def handle_event(_event, _params, socket), do: {:cont, socket}

  @doc false
  def handle_info(:exberly_conn_tick, socket) do
    Process.send_after(self(), :exberly_conn_tick, @refresh_ms)
    {:halt, refresh(socket)}
  end

  def handle_info({:exberly_target, {:connected, node}}, socket),
    do:
      {:cont,
       socket
       |> update(status: :connected, node: node, error: nil, node_input: Atom.to_string(node))
       |> refresh()}

  def handle_info({:exberly_target, {:disconnected, reason}}, socket) do
    error = if reason == :nodedown, do: "Lost the connection to #{socket.assigns.conn.node}."
    {:cont, update(socket, status: :disconnected, node: nil, info: nil, error: error)}
  end

  def handle_info(_message, socket), do: {:cont, socket}

  defp refresh(%{assigns: %{conn: %{status: :connected}}} = socket) do
    case Target.node_info() do
      {:ok, info} -> update(socket, info: info)
      {:error, _} -> socket
    end
  end

  defp refresh(socket), do: socket

  defp update(socket, changes),
    do: assign(socket, :conn, Map.merge(socket.assigns.conn, Map.new(changes)))

  @doc "Forgets a node typed in this session that did not connect."
  def forget_typed do
    :persistent_term.erase(@last_node)
    :ok
  end

  defp last_node(saved), do: :persistent_term.get(@last_node, saved)
end
