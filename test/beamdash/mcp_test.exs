defmodule Beamdash.McpTest do
  use ExUnit.Case, async: false

  alias Beamdash.{Mcp, Target}
  alias Beamdash.Test.Fixture

  defp unique_name, do: :"mcp_target_#{System.unique_integer([:positive])}"

  test "every tool says so when no node is connected" do
    target = start_supervised!({Target, name: unique_name()})

    assert {:error, "beamdash is not connected to a node"} =
             Mcp.call("node_info", %{}, target)
  end

  test "a name that is not one of the tools is reported as unknown" do
    assert :unknown_tool = Mcp.call("kill_process", %{})
  end

  describe "on a connected node" do
    setup do
      {peer, node} = Fixture.start_peer()
      on_exit(fn -> Fixture.stop_peer(peer) end)

      target = start_supervised!({Target, name: unique_name()})
      {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie(), target)
      %{node: node, target: target}
    end

    test "node_info describes the peer", %{node: node, target: target} do
      assert {:ok, %{node: ^node, process_count: count}} = Mcp.call("node_info", %{}, target)
      assert is_integer(count)
    end

    test "list_processes honours the limit and sorts by memory", %{target: target} do
      assert {:ok, procs} = Mcp.call("list_processes", %{"limit" => 3}, target)
      assert length(procs) == 3
      memories = Enum.map(procs, & &1.memory)
      assert memories == Enum.sort(memories, :desc)
      assert Enum.all?(procs, &(&1.pid =~ ~r/^<\d+\.\d+\.\d+>$/))
    end

    test "process_details takes a pid as list_processes shows it", %{target: target} do
      {:ok, [%{pid: pid} | _]} = Mcp.call("list_processes", %{"limit" => 1}, target)

      assert {:ok, %{pid: ^pid, memory: %{total: _}}} =
               Mcp.call("process_details", %{"pid" => pid}, target)
    end

    test "process_details refuses text that is not a pid", %{target: target} do
      assert {:error, "pid must look like <0.123.0>" <> _} =
               Mcp.call("process_details", %{"pid" => "nope"}, target)
    end

    test "ets_tables lists the tables of the node", %{target: target} do
      assert {:ok, tables} = Mcp.call("ets_tables", %{}, target)
      assert Enum.any?(tables, &(&1.name == :ac_tab))
    end
  end
end
