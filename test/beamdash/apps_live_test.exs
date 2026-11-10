defmodule Beamdash.AppsLiveTest do
  # The Apps tab against a peer node running kernel. The applications come
  # from the application cache, which is fed by the connected target.
  use ExUnit.Case, async: false

  alias Beamdash.{Target}
  alias Beamdash.Test.Fixture
  alias BeamdashWeb.AppsLive
  alias Phoenix.Component

  setup do
    {peer, node} = Fixture.start_peer()
    {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie())

    on_exit(fn ->
      Target.disconnect()
      Fixture.stop_peer(peer)
    end)

    %{node: node}
  end

  defp cold_socket(node) do
    socket = %Phoenix.LiveView.Socket{
      transport_pid: self(),
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    Component.assign(socket,
      status: :connected,
      node: node,
      apps: [],
      app: nil,
      tree: nil,
      info: nil,
      error: nil,
      selected: nil,
      proc: nil
    )
  end

  test "a ?app= link on a cold page opens that application, loading its tree once", ctx do
    {:noreply, socket} =
      AppsLive.handle_params(%{"app" => "kernel"}, "http://localhost/apps", cold_socket(ctx.node))

    assert socket.assigns.loading == :shown
    socket = async_result(socket, :load)

    assert socket.assigns.app == :kernel
    assert socket.assigns.tree != nil
    refute_receive {:phoenix, :async_result, {:start, {_, _, :load, _}}}, 100
  end

  test "the Tree switch sets the process tree to outline, and Graph sets it back", ctx do
    socket = Component.assign(cold_socket(ctx.node), tree_mode: :graph)

    {:noreply, socket} = AppsLive.handle_event("tree_mode", %{"mode" => "tree"}, socket)
    assert socket.assigns.tree_mode == :tree

    {:noreply, socket} = AppsLive.handle_event("tree_mode", %{"mode" => "graph"}, socket)
    assert socket.assigns.tree_mode == :graph
  end

  test "the Order by switch sets the metric the tree is ordered by", ctx do
    socket = Component.assign(cold_socket(ctx.node), tree_metric: :structure)

    {:noreply, socket} = AppsLive.handle_event("tree_metric", %{"by" => "reductions"}, socket)
    assert socket.assigns.tree_metric == :reductions

    {:noreply, socket} = AppsLive.handle_event("tree_metric", %{"by" => "mailbox"}, socket)
    assert socket.assigns.tree_metric == :mailbox
  end

  # the start_async task's result, as LiveView hands it back
  defp async_result(socket, key) do
    assert_receive {:phoenix, :async_result, {:start, {_ref, nil, ^key, result}}}, 15_000
    {:noreply, socket} = AppsLive.handle_async(key, result, socket)
    socket
  end
end
