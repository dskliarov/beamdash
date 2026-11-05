defmodule Beamdash.AppsLiveTest do
  # The Apps tab against this node, which always runs kernel.
  use ExUnit.Case, async: true

  alias Beamdash.Apps
  alias BeamdashWeb.AppsLive
  alias Phoenix.Component

  defp cold_socket do
    Component.assign(%Phoenix.LiveView.Socket{},
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
    Code.ensure_loaded!(Apps)
    :erlang.trace_pattern({Apps, :tree, 2}, true, [:global])
    test_pid = self()

    try do
      {:noreply, socket} =
        Task.async(fn ->
          :erlang.trace(self(), true, [:call, {:tracer, test_pid}])
          AppsLive.handle_params(%{"app" => "kernel"}, "http://localhost/apps", cold_socket())
        end)
        |> Task.await()

      assert socket.assigns.app == :kernel
      assert socket.assigns.tree != nil
      assert tree_calls() == 1
    after
      :erlang.trace_pattern({Apps, :tree, 2}, false, [:global])
    end
  end

  test "the Tree switch sets the process tree to outline, and Graph sets it back" do
    socket = Component.assign(cold_socket(), tree_mode: :graph)

    {:noreply, socket} = AppsLive.handle_event("tree_mode", %{"mode" => "tree"}, socket)
    assert socket.assigns.tree_mode == :tree

    {:noreply, socket} = AppsLive.handle_event("tree_mode", %{"mode" => "graph"}, socket)
    assert socket.assigns.tree_mode == :graph
  end

  defp tree_calls do
    receive do
      {:trace, _, :call, {Apps, :tree, _}} -> 1 + tree_calls()
    after
      0 -> 0
    end
  end
end
