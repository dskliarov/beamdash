defmodule HelloPlugin.HelloLive do
  @moduledoc """
  The fixture plugin's page: the attached node, the result of an rpc to it
  (`erlang:node/0`), and a counter set by `{:hello_count, n}` messages.
  """
  use Beamdash.Plugin.Page

  @impl true
  def plugin_mount(_params, _session, socket) do
    {:ok, socket |> assign(count: 0) |> load()}
  end

  @impl true
  def connection_changed(_event, socket), do: {:noreply, load(socket)}

  @impl true
  def plugin_info({:hello_count, n}, socket), do: {:noreply, assign(socket, count: n)}
  def plugin_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="hello_plugin-page">
      <p id="hello-plugin">Hello from {@node || "nowhere"}</p>
      <p id="hello-plugin-rpc">{Beamdash.Plugin.Format.term(@remote, @syntax)}</p>
      <p id="hello-plugin-count">{@count}</p>
    </div>
    """
  end

  defp load(socket) do
    remote =
      if connected?(socket),
        do: Beamdash.Plugin.rpc(:erlang, :node, [], 5_000, target: socket.assigns.beamdash_target)

    assign(socket, remote: remote)
  end
end
