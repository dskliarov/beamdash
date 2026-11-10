defmodule Beamdash.McpTest do
  use ExUnit.Case, async: false

  alias Beamdash.{Format, Mcp, Settings, Store, Target}
  alias Beamdash.Test.Fixture

  defp unique_name, do: :"mcp_target_#{System.unique_integer([:positive])}"

  defp start_store do
    dir = Path.join(System.tmp_dir!(), "beamdash_mcp_#{System.unique_integer([:positive])}")
    start_supervised!({Store, path: Path.join(dir, "events.sqlite3"), purge_interval: :infinity})
    on_exit(fn -> File.rm_rf(dir) end)
  end

  defp snapshot(at, node, pid, reason) do
    %{
      at: at,
      node: node,
      pid: pid,
      reason: reason,
      data: %{"process" => %{"memory" => 1_000}, "rate" => 0}
    }
  end

  test "every tool says so when no node is connected" do
    target = start_supervised!({Target, name: unique_name()})

    assert {:error, "beamdash is not connected to a node"} =
             Mcp.call("node_info", %{}, target)
  end

  test "the new tools say so when no node is connected" do
    target = start_supervised!({Target, name: unique_name()})

    for {name, args} <- [
          {"memory_history", %{}},
          {"ets_rows", %{"table" => "ac_tab"}},
          {"source_check", %{"app" => "kernel"}}
        ] do
      assert {:error, "beamdash is not connected to a node"} = Mcp.call(name, args, target)
    end
  end

  test "a name that is not one of the tools is reported as unknown" do
    assert :unknown_tool = Mcp.call("kill_process", %{})
  end

  defmodule StubPlugins do
    use GenServer

    def start_link(active), do: GenServer.start_link(__MODULE__, active)

    @impl true
    def init(active), do: {:ok, active}

    @impl true
    def handle_call(:active, _from, active), do: {:reply, active, active}
  end

  defmodule Tools do
    def ok(args), do: {:ok, %{got: args}}
    def error(_args), do: {:error, "nope"}
    def raises(_args), do: raise("boom")
    def odd(_args), do: :odd
    def greet(%{"name" => name}), do: {:ok, %{greeting: "Hello, #{name}!"}}
  end

  describe "tools of active plugins" do
    setup do
      tool = fn name, fun ->
        %{
          name: name,
          description: "Tool #{name}",
          input_schema: %{type: "object", properties: %{}},
          call: {Tools, fun}
        }
      end

      tools = [
        tool.("ok", :ok),
        tool.("error", :error),
        tool.("raises", :raises),
        tool.("odd", :odd),
        %{
          name: "greet",
          description: "Tool greet",
          input_schema: %{type: "object", required: ["name"]},
          call: {Tools, :greet}
        }
      ]

      plugins = start_supervised!({StubPlugins, [%{app: :ring_app, mcp_tools: tools}]})
      %{plugins: plugins}
    end

    test "are listed as app.tool, with their schema and no call", %{plugins: plugins} do
      assert %{
               name: "ring_app.ok",
               description: "Tool ok",
               inputSchema: %{type: "object", properties: %{}}
             } in Mcp.tools(plugins)

      refute Enum.any?(Mcp.tools(plugins), &Map.has_key?(&1, :call))
    end

    test "run with their arguments and return the data", %{plugins: plugins} do
      assert {:ok, %{got: %{"x" => 1}}} = Mcp.call("ring_app.ok", %{"x" => 1}, Target, plugins)
    end

    test "report an error they return", %{plugins: plugins} do
      assert {:error, "nope"} = Mcp.call("ring_app.error", %{}, Target, plugins)
    end

    test "report a raise instead of raising", %{plugins: plugins} do
      assert {:error, "ring_app.raises raised boom"} =
               Mcp.call("ring_app.raises", %{}, Target, plugins)
    end

    test "report a value that is not a result", %{plugins: plugins} do
      assert {:error, "ring_app.odd returned :odd"} =
               Mcp.call("ring_app.odd", %{}, Target, plugins)
    end

    test "a call without a required argument says which one is missing", %{plugins: plugins} do
      assert {:error, "ring_app.greet needs name"} =
               Mcp.call("ring_app.greet", %{}, Target, plugins)

      assert {:error, "ring_app.greet needs name"} =
               Mcp.call("ring_app.greet", "not a map", Target, plugins)

      assert {:ok, %{greeting: "Hello, Ada!"}} =
               Mcp.call("ring_app.greet", %{"name" => "Ada"}, Target, plugins)
    end

    test "a name no active plugin declares is unknown", %{plugins: plugins} do
      assert :unknown_tool = Mcp.call("ring_app.gone", %{}, Target, plugins)
      assert :unknown_tool = Mcp.call("other_app.ok", %{}, Target, plugins)
    end

    test "tools of a plugin that is not active are not offered" do
      plugins = start_supervised!({StubPlugins, []}, id: :no_plugins)

      refute Enum.any?(Mcp.tools(plugins), &String.starts_with?(&1.name, "ring_app."))
      assert :unknown_tool = Mcp.call("ring_app.ok", %{}, Target, plugins)
    end
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

    test "snapshots lists the attached node's rows, newest first, with an optional reason", %{
      node: node,
      target: target
    } do
      start_store()
      :ok = Settings.put_snapshots_enabled(true)
      on_exit(fn -> :ok = Settings.put_snapshots_enabled(false) end)

      now = System.system_time(:millisecond)
      name = Atom.to_string(node)

      :ok =
        Store.record(:snapshots, [
          snapshot(now - 2_000, name, "#PID<0.3.0>", "memory"),
          snapshot(now - 1_000, name, "#PID<0.1.0>", "load"),
          snapshot(now - 1_000, "other@host", "#PID<0.2.0>", "load")
        ])

      assert {:ok, [newest, oldest]} = Mcp.call("snapshots", %{}, target)
      assert %{pid: "<0.1.0>", reason: "load"} = newest
      assert %{pid: "<0.3.0>", reason: "memory"} = oldest
      assert {:ok, [%{pid: "<0.3.0>"}]} = Mcp.call("snapshots", %{"reason" => "memory"}, target)

      assert {:error, "pid must look like" <> _} =
               Mcp.call("snapshots", %{"pid" => "nope"}, target)
    end

    test "anomaly_history lists the attached node's episodes, filtered by pid and measure", %{
      node: node,
      target: target
    } do
      start_store()
      :ok = Settings.put_snapshots_enabled(true)
      on_exit(fn -> :ok = Settings.put_snapshots_enabled(false) end)

      now = System.system_time(:millisecond)

      :ok =
        Store.record(:anomalies, [
          %{
            at: now - 1_000,
            node: Atom.to_string(node),
            pid: "#PID<0.5.0>",
            measure: "mailbox",
            data: %{"kind" => "rising", "text" => "queue grew", "duration_ms" => 500}
          }
        ])

      assert {:ok, [episode]} = Mcp.call("anomaly_history", %{"pid" => "<0.5.0>"}, target)
      assert %{pid: "<0.5.0>", measure: "mailbox"} = episode
      assert {:ok, []} = Mcp.call("anomaly_history", %{"measure" => "reductions"}, target)
    end

    test "memory_history lists the node's samples, with one table's entry when asked", %{
      node: node,
      target: target
    } do
      start_store()
      :ok = Settings.put_snapshots_enabled(true)
      on_exit(fn -> :ok = Settings.put_snapshots_enabled(false) end)

      now = System.system_time(:millisecond)
      name = Atom.to_string(node)

      rig_locks = %{
        "name" => "rig_locks",
        "type" => "set",
        "size" => 3,
        "memory" => 400,
        "owner" => "<0.9.0>"
      }

      :ok =
        Store.record(:memory, [
          %{
            at: now - 2_000,
            node: name,
            data: %{
              "memory" => %{"total" => 100},
              "atom_count" => 5,
              "ets_count" => 1,
              "tables" => [rig_locks]
            }
          },
          %{
            at: now - 1_000,
            node: name,
            data: %{
              "memory" => %{"total" => 200},
              "atom_count" => 6,
              "ets_count" => 2,
              "tables" => []
            }
          },
          %{
            at: now - 1_000,
            node: "other@host",
            data: %{
              "memory" => %{"total" => 999},
              "atom_count" => 1,
              "ets_count" => 0,
              "tables" => []
            }
          }
        ])

      assert {:ok, %{rows: [newest, oldest], truncated: false}} =
               Mcp.call("memory_history", %{}, target)

      assert %{memory: 200, atom_count: 6, ets_count: 2} = newest
      refute Map.has_key?(newest, :table)
      assert %{memory: 100} = oldest

      assert {:ok, %{rows: [without, with_table]}} =
               Mcp.call("memory_history", %{"table" => "rig_locks"}, target)

      assert %{table: nil} = without

      assert %{table: %{name: "rig_locks", type: "set", size: 3, memory: 400, owner: "<0.9.0>"}} =
               with_table

      assert {:ok, %{rows: [_], truncated: true}} =
               Mcp.call("memory_history", %{"limit" => 1}, target)
    end

    test "ets_rows reads rows of a table, capped at the limit", %{target: target} do
      assert {:ok, %{table: :ac_tab, rows: rows, stop: stop}} =
               Mcp.call("ets_rows", %{"table" => "ac_tab", "limit" => 1}, target)

      assert length(rows) <= 1
      assert stop in [:complete, :rows, :time]
    end

    test "ets_rows says what is wrong with the table it was given", %{target: target} do
      assert {:error, "table must be" <> _} = Mcp.call("ets_rows", %{}, target)

      assert {:error, message} = Mcp.call("ets_rows", %{"table" => "no_such_table_xyz"}, target)
      assert message =~ "ets_tables"
    end

    test "source_check reports an application without a configured folder", %{target: target} do
      assert {:ok, %{app: :kernel, status: "no_folder", vsn: vsn}} =
               Mcp.call("source_check", %{"app" => "kernel"}, target)

      assert is_binary(vsn)
    end

    test "source_check names an application that is not on the node", %{target: target} do
      assert {:error, message} =
               Mcp.call("source_check", %{"app" => "no_such_application_xyz"}, target)

      assert message =~ "app_list"
    end

    test "the stored history says so when snapshot collection is off", %{target: target} do
      start_store()
      :ok = Settings.put_snapshots_enabled(false)

      assert {:error, "snapshot collection is off" <> _} = Mcp.call("snapshots", %{}, target)

      assert {:error, "snapshot collection is off" <> _} =
               Mcp.call("anomaly_history", %{}, target)

      assert {:error, "snapshot collection is off" <> _} =
               Mcp.call("memory_history", %{}, target)
    end

    test "the stored history says so when the event store is not running", %{target: target} do
      :ok = Settings.put_snapshots_enabled(true)
      on_exit(fn -> :ok = Settings.put_snapshots_enabled(false) end)

      assert {:error, "the event store is not running"} = Mcp.call("snapshots", %{}, target)
    end
  end
end
