defmodule Beamdash.McpTest do
  use ExUnit.Case, async: false

  alias Beamdash.{Format, Mcp, Target}
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

    test "process_details takes a pid as list_processes shows it", %{node: node, target: target} do
      text = Format.pid(:erpc.call(node, :erlang, :spawn, [:timer, :sleep, [:infinity]]))

      assert {:ok, procs} = Mcp.call("list_processes", %{"limit" => 1000}, target)
      assert text in Enum.map(procs, & &1.pid)

      assert {:ok, %{pid: ^text, memory: %{total: _}}} =
               Mcp.call("process_details", %{"pid" => text}, target)
    end

    test "process_details leaves queued messages out", %{node: node, target: target} do
      pid = :erpc.call(node, :erlang, :spawn, [:timer, :sleep, [:infinity]])
      :erpc.call(node, :erlang, :send, [pid, :secret])

      assert {:ok, %{mailbox: %{length: 1, messages: :not_fetched}}} =
               Mcp.call("process_details", %{"pid" => Format.pid(pid)}, target)
    end

    test "process_details says so once the process has exited", %{node: node, target: target} do
      pid = :erpc.call(node, :erlang, :spawn, [:erlang, :exit, [:normal]])
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      assert {:error, "that process has exited"} =
               Mcp.call("process_details", %{"pid" => Format.pid(pid)}, target)
    end

    test "process_details refuses text that is not a pid", %{target: target} do
      assert {:error, "pid must look like <0.123.0>" <> _} =
               Mcp.call("process_details", %{"pid" => "nope"}, target)
    end

    test "ets_tables lists the tables of the node", %{target: target} do
      assert {:ok, tables} = Mcp.call("ets_tables", %{}, target)
      assert Enum.any?(tables, &(&1.name == :ac_tab))
    end

    test "app_list names the running applications, kernel among them", %{target: target} do
      assert {:ok, apps} = Mcp.call("app_list", %{}, target)
      assert Enum.any?(apps, &(&1.name == :kernel))
    end

    test "app_info and app_tree describe a running application", %{target: target} do
      assert {:ok, %{vsn: vsn}} = Mcp.call("app_info", %{"app" => "kernel"}, target)
      assert is_binary(vsn)

      assert {:ok, %{count: count}} = Mcp.call("app_tree", %{"app" => "kernel"}, target)
      assert is_integer(count)
    end

    test "an application name that is not known is refused, with a hint", %{target: target} do
      assert {:error, message} =
               Mcp.call("app_tree", %{"app" => "no_such_application_xyz"}, target)

      assert message =~ "app_list"
    end

    test "app_info needs the app argument", %{target: target} do
      assert {:error, "app must be" <> _} = Mcp.call("app_info", %{}, target)
    end

    test "module_summary describes a loaded module", %{target: target} do
      assert {:ok, %{module: :application}} =
               Mcp.call("module_summary", %{"module" => "application"}, target)
    end

    test "module_summary says so for a module the node does not have", %{target: target} do
      assert {:error, message} = Mcp.call("module_summary", %{"module" => "Beamdash.Mcp"}, target)
      assert message =~ "not loaded"
    end

    test "crashes and logs answer with lists, newest first", %{target: target} do
      assert {:ok, crashes} = Mcp.call("crashes", %{"limit" => 5}, target)
      assert is_list(crashes) and length(crashes) <= 5

      assert {:ok, entries} = Mcp.call("logs", %{"limit" => 5}, target)
      assert is_list(entries) and length(entries) <= 5
    end

    test "logs filters by level", %{target: target} do
      assert {:ok, entries} = Mcp.call("logs", %{"level" => "error"}, target)
      assert Enum.all?(entries, &(&1.level == :error))
    end
  end
end
