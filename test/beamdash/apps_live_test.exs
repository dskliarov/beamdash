defmodule Beamdash.AppsLiveTest do
  # The Apps tab against this node, which always runs kernel.
  use ExUnit.Case, async: true

  alias BeamdashWeb.AppsLive
  alias Phoenix.Component

  defp cold_socket do
    socket = %Phoenix.LiveView.Socket{
      transport_pid: self(),
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    Component.assign(socket,
      status: :connected,
      node: node(),
      apps: [],
      app: nil,
      tree: nil,
      info: nil,
      error: nil,
      selected: nil,
      proc: nil
    )
  end

  test "a ?app= link on a cold page opens that application, loading its tree once" do
    {:noreply, socket} =
      AppsLive.handle_params(%{"app" => "kernel"}, "http://localhost/apps", cold_socket())

    assert socket.assigns.loading == :shown
    socket = async_result(socket, :load)

    assert socket.assigns.app == :kernel
    assert socket.assigns.tree != nil
    refute_receive {:phoenix, :async_result, {:start, {_, _, :load, _}}}, 100
  end

  test "the Tree switch sets the process tree to outline, and Graph sets it back" do
    socket = Component.assign(cold_socket(), tree_mode: :graph)

    {:noreply, socket} = AppsLive.handle_event("tree_mode", %{"mode" => "tree"}, socket)
    assert socket.assigns.tree_mode == :tree

    {:noreply, socket} = AppsLive.handle_event("tree_mode", %{"mode" => "graph"}, socket)
    assert socket.assigns.tree_mode == :graph
  end

  # the start_async task's result, as LiveView hands it back
  defp async_result(socket, key) do
    assert_receive {:phoenix, :async_result, {:start, {_ref, nil, ^key, result}}}, 15_000
    {:noreply, socket} = AppsLive.handle_async(key, result, socket)
    socket
  end
end
