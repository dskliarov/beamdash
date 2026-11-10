defmodule Beamdash.TraceTreeClickTest do
  # Clicking branches of the trace log's Tree tab against a real node.
  use ExUnit.Case, async: false

  alias Beamdash.{Target, Tracer}
  alias Beamdash.Test.Fixture
  alias Beamdash.Trace.Tree
  alias BeamdashWeb.TraceLive

  defp html(socket),
    do: TraceLive.render(socket.assigns) |> Phoenix.LiveViewTest.rendered_to_string()

  defp event(socket, name, params) do
    {:noreply, socket} = TraceLive.handle_event(name, params, socket)
    socket
  end

  defp wait_for_entries(0), do: Tracer.entries()

  defp wait_for_entries(n) do
    case Tracer.entries() do
      [] ->
        Process.sleep(20)
        wait_for_entries(n - 1)

      entries ->
        entries
    end
  end

  describe "against a node" do
    setup do
      {peer, node} = Fixture.start_peer()
      {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie())
      :ok = Fixture.load(node)

      on_exit(fn ->
        Tracer.stop_all()
        Target.disconnect()
        Fixture.stop_peer(peer)
      end)

      socket = %Phoenix.LiveView.Socket{
        private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
      }

      {:ok, socket} = TraceLive.mount(%{}, %{}, socket)
      {:ok, modules} = Tracer.module_functions()

      socket =
        Phoenix.Component.assign(socket,
          syntax: :erlang,
          status: :connected,
          node: node,
          modules: modules
        )
        |> event("select_module", %{"mod" => "beamdash_fixture"})
        |> event("select_function", %{"fun" => "add", "arity" => "2"})
        |> event("trace_picked", %{"limit" => ""})

      assert :ok = wait_until_traced([{:beamdash_fixture, :add, 2}])
      assert 3 = :erpc.call(node, :beamdash_fixture, :add, [1, 2])
      assert [_ | _] = wait_for_entries(50)

      socket = event(socket, "log_tab", %{"tab" => "tree"})
      %{socket: socket}
    end

    test "clicking a module opens its functions and keeps the log as it is", %{socket: s} do
      assert s.assigns.log_tab == :tree
      assert s.assigns.log_filter == nil
      refute html(s) =~ ~s(id="trace-tree-f:beamdash_fixture:add/2")

      s = event(s, "tree_toggle", %{"id" => "m:beamdash_fixture"})

      assert s.assigns.log_tab == :tree
      assert s.assigns.log_filter == nil
      assert "m:beamdash_fixture" in s.assigns.tree_open
      assert html(s) =~ ~s(id="trace-tree-f:beamdash_fixture:add/2")
    end

    test "Show in log on a module filters the log to it", %{socket: s} do
      s = event(s, "tree_show", %{"id" => "m:beamdash_fixture"})

      assert s.assigns.log_tab == :lines
      assert s.assigns.log_filter == {:module, :beamdash_fixture}
    end

    test "clicking a call opens that call in the log", %{socket: s} do
      s = event(s, "tree_toggle", %{"id" => "m:beamdash_fixture"})
      s = event(s, "tree_toggle", %{"id" => "f:beamdash_fixture:add/2"})
      s = event(s, "tree_toggle", %{"id" => "r:beamdash_fixture:add/2:ok"})

      [call | _] = Tree.find(s.assigns.trace_tree.nodes, "r:beamdash_fixture:add/2:ok").children
      call_id = elem(call.scope, 1)
      s = event(s, "tree_show", %{"id" => call.id})

      assert s.assigns.log_tab == :lines
      assert s.assigns.log_filter == {:call, call_id}
      assert s.assigns.detail.id == call_id
    end
  end

  defp wait_until_traced(mfas, n \\ 50)
  defp wait_until_traced(_mfas, 0), do: {:error, :not_traced}

  defp wait_until_traced(mfas, n) do
    if Enum.all?(mfas, &(&1 in Tracer.traces())) do
      :ok
    else
      Process.sleep(20)
      wait_until_traced(mfas, n - 1)
    end
  end
end
