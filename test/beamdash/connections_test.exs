defmodule Beamdash.ConnectionsTest do
  use ExUnit.Case, async: false

  alias Beamdash.{
    AnomalyMonitor,
    Connections,
    Crashes,
    Logs,
    Profiler,
    Sampler,
    SeqTracer,
    Settings,
    SysTracer,
    Target,
    Tracer
  }

  alias Beamdash.Test.Fixture

  setup do
    Target.disconnect()
    previous_method = Settings.connection_method()
    :ok = Settings.put_connection_method(:direct)
    :ok = Settings.put_multiple_connections(true)

    on_exit(fn ->
      for %{server: server} <- Connections.list(),
          server != Target,
          do: Connections.remove(server)

      Target.disconnect()
      Settings.put_multiple_connections(false)
      Settings.put_connection_method(previous_method)
    end)

    :ok
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition not met in time")

      true ->
        Process.sleep(20)
        eventually(fun, tries - 1)
    end
  end

  defp connect_extra(node) do
    server = Connections.target_for_connect()
    {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie(), server)
    server
  end

  test "the first connection's instances are the singletons" do
    assert Connections.service(Target, AnomalyMonitor) == AnomalyMonitor
    assert Connections.service(Target, Sampler) == Sampler
  end

  test "an extra connection gets its own anomaly monitor, reading its own node" do
    {_peer1, node1} = Fixture.start_peer()
    {_peer2, node2} = Fixture.start_peer()

    {:ok, _} = Target.connect(Atom.to_string(node1), Fixture.cookie())
    extra = connect_extra(node2)

    monitor = Connections.service(extra, AnomalyMonitor)
    assert is_pid(monitor)
    refute monitor == AnomalyMonitor
    assert Process.alive?(monitor)

    :ok = AnomalyMonitor.tick(monitor)
    assert :sys.get_state(monitor).node == Atom.to_string(node2)

    :ok = AnomalyMonitor.tick(AnomalyMonitor)
    assert :sys.get_state(AnomalyMonitor).node == Atom.to_string(node1)
  end

  test "an extra connection gets idle instances aimed at its own node" do
    {_peer1, node1} = Fixture.start_peer()
    {_peer2, node2} = Fixture.start_peer()
    {:ok, _} = Target.connect(Atom.to_string(node1), Fixture.cookie())
    extra = connect_extra(node2)

    for module <- [Tracer, SysTracer, SeqTracer, Profiler] do
      pid = Connections.service(extra, module)
      assert is_pid(pid)
      assert :sys.get_state(pid).target == extra
    end

    tracer = Connections.service(extra, Tracer)
    assert :sys.get_state(Connections.service(extra, SeqTracer)).tracer == tracer

    crashes = Connections.service(extra, Crashes)
    assert is_pid(crashes)
    assert :sys.get_state(crashes).target == extra

    # storing is off in tests, so no sampler, as at startup
    assert Connections.service(extra, Sampler) == nil
  end

  test "stopping one node's crashes leaves the others running" do
    {_peer1, node1} = Fixture.start_peer()
    {_peer2, node2} = Fixture.start_peer()
    {:ok, _} = Target.connect(Atom.to_string(node1), Fixture.cookie())
    extra = connect_extra(node2)
    crashes = Connections.service(extra, Crashes)
    primary_crashes = Process.whereis(Crashes)

    assert :ok = Connections.stop_service(extra, Crashes)

    refute Process.alive?(crashes)
    assert Connections.service(extra, Crashes) == nil
    assert Process.alive?(primary_crashes)
    assert Target.status(Target).status == :connected
    assert Target.status(extra).status == :connected
  end

  test "an extra connection gets its own log stream, fed only by its own node" do
    {_peer1, node1} = Fixture.start_peer()
    {_peer2, node2} = Fixture.start_peer()
    {:ok, _} = Target.connect(Atom.to_string(node1), Fixture.cookie())
    extra = connect_extra(node2)

    logs = Connections.service(extra, Logs)
    assert is_pid(logs)
    assert :sys.get_state(logs).target == extra

    :ok = Logs.subscribe(logs)
    eventually(fn -> Logs.info(logs).status == :streaming end)

    :ok = Fixture.log(node2, :error, "from the extra node")
    assert_receive {:beamdash_logs, {:entries, [_ | _]}}, 3_000

    assert Enum.any?(Logs.entries(logs), &(&1.message == "from the extra node"))
    refute Enum.any?(Logs.entries(), &(&1.message == "from the extra node"))
  end

  test "a stopped node's crashes can be started again, on the same node" do
    {_peer1, node1} = Fixture.start_peer()
    {_peer2, node2} = Fixture.start_peer()
    {:ok, _} = Target.connect(Atom.to_string(node1), Fixture.cookie())
    extra = connect_extra(node2)

    assert {:error, :running} = Connections.start_service(extra, Crashes)
    :ok = Connections.stop_service(extra, Crashes)
    assert Connections.service(extra, Crashes) == nil

    assert {:ok, crashes} = Connections.start_service(extra, Crashes)
    assert Connections.service(extra, Crashes) == crashes
    assert :sys.get_state(crashes).target == extra
    assert Connections.start_service(Target, Crashes) == {:error, :not_found}
  end

  test "removing an extra connection ends its instances and leaves the others running" do
    {_peer1, node1} = Fixture.start_peer()
    {_peer2, node2} = Fixture.start_peer()

    {:ok, _} = Target.connect(Atom.to_string(node1), Fixture.cookie())
    extra = connect_extra(node2)

    instances =
      for module <- [AnomalyMonitor, Logs, Crashes, Tracer, SysTracer, SeqTracer, Profiler],
          do: Connections.service(extra, module)

    :ok = Connections.remove(extra)

    for pid <- instances, do: refute(Process.alive?(pid))
    assert Connections.service(extra, AnomalyMonitor) == nil
    assert Process.alive?(Process.whereis(AnomalyMonitor))
    assert Target.status().status == :connected
  end

  test "list shows the first connection, then the extra ones, with their nodes" do
    {_peer1, node1} = Fixture.start_peer()
    {_peer2, node2} = Fixture.start_peer()
    {:ok, _} = Target.connect(Atom.to_string(node1), Fixture.cookie())
    extra = connect_extra(node2)

    assert [
             %{server: Target, node: ^node1, status: :connected, reconnecting: nil},
             %{server: ^extra, node: ^node2, status: :connected}
           ] = Connections.list()
  end

  test "a disconnected first connection is no longer listed, the extra ones stay" do
    {_peer1, node1} = Fixture.start_peer()
    {_peer2, node2} = Fixture.start_peer()
    {:ok, _} = Target.connect(Atom.to_string(node1), Fixture.cookie())
    extra = connect_extra(node2)

    :ok = Connections.remove(Target)

    assert [%{server: ^extra, node: ^node2}] = Connections.list()
  end

  test "prune ends an extra connection that dropped and is not reconnecting" do
    {_peer1, node1} = Fixture.start_peer()
    {_peer2, node2} = Fixture.start_peer()
    {:ok, _} = Target.connect(Atom.to_string(node1), Fixture.cookie())
    extra = connect_extra(node2)
    monitor = Connections.service(extra, AnomalyMonitor)

    :ok = Target.disconnect(extra)
    assert [%{server: Target}] = Connections.list()
    assert Process.alive?(monitor)

    :ok = Connections.prune()

    refute Process.alive?(monitor)
    assert Connections.service(extra, AnomalyMonitor) == nil
    assert Target.status().status == :connected
  end

  test "target_for_connect picks the first connection while it is free, then a new one" do
    assert Connections.target_for_connect() == Target
    {_peer1, node1} = Fixture.start_peer()
    {:ok, _} = Target.connect(Atom.to_string(node1), Fixture.cookie())

    extra = Connections.target_for_connect()
    assert is_pid(extra)
    refute extra == Target
    assert Connections.service(extra, AnomalyMonitor) != nil
  end

  test "discard ends a connection that never connected, and keeps a connected one" do
    {_peer1, node1} = Fixture.start_peer()
    {_peer2, node2} = Fixture.start_peer()
    {:ok, _} = Target.connect(Atom.to_string(node1), Fixture.cookie())

    unconnected = Connections.target_for_connect()
    monitor = Connections.service(unconnected, AnomalyMonitor)
    assert :ok = Connections.discard(unconnected)
    refute Process.alive?(monitor)
    assert Connections.service(unconnected, AnomalyMonitor) == nil

    connected = connect_extra(node2)
    assert :ok = Connections.discard(connected)
    assert Target.status(connected).status == :connected
  end

  test "with multiple connections off, target_for_connect ends the extra connections" do
    {_peer1, node1} = Fixture.start_peer()
    {_peer2, node2} = Fixture.start_peer()
    {:ok, _} = Target.connect(Atom.to_string(node1), Fixture.cookie())
    extra = connect_extra(node2)
    monitor = Connections.service(extra, AnomalyMonitor)

    :ok = Settings.put_multiple_connections(false)

    assert Connections.target_for_connect() == Target
    refute Process.alive?(monitor)
    assert Connections.list() |> Enum.map(& &1.server) == [Target]
  end

  test "with storing on, an extra connection gets a sampler wired to its own monitor" do
    path =
      Path.join(
        System.tmp_dir!(),
        "beamdash_sampler_#{System.unique_integer([:positive])}.sqlite3"
      )

    Application.put_env(:beamdash, :store_file, path)
    on_exit(fn -> Application.put_env(:beamdash, :store_file, false) end)

    {_peer1, node1} = Fixture.start_peer()
    {_peer2, node2} = Fixture.start_peer()
    {:ok, _} = Target.connect(Atom.to_string(node1), Fixture.cookie())
    extra = connect_extra(node2)

    sampler = Connections.service(extra, Sampler)
    assert is_pid(sampler)
    assert :sys.get_state(sampler).monitor == Connections.service(extra, AnomalyMonitor)
  end

  describe "application rule" do
    test "another application is refused, the same application is allowed" do
      {_peer, node} = Fixture.start_peer()
      name = Atom.to_string(node)
      {:ok, _} = Target.connect(name, Fixture.cookie())
      identity = {:direct, Connections.node_app(name)}
      :ok = Connections.record_application(Target, identity)

      assert Connections.app() == identity
      assert :ok = Connections.check_application(identity, name)

      assert {:error, {:different_application, app, "other@host", "other"}} =
               Connections.check_application({:direct, "other"}, "other@host")

      assert app == Connections.node_app(name)
    end

    test "a direct and a kubectl connection never share an application" do
      {_peer, node} = Fixture.start_peer()
      name = Atom.to_string(node)
      {:ok, _} = Target.connect(name, Fixture.cookie())
      app = Connections.node_app(name)
      :ok = Connections.record_application(Target, {:direct, app})

      assert {:error, {:different_application, ^app, "api-0", ^app}} =
               Connections.check_application({:kubectl, app}, "api-0")
    end

    test "disconnecting every connection clears the application" do
      {_peer, node} = Fixture.start_peer()
      name = Atom.to_string(node)
      {:ok, _} = Target.connect(name, Fixture.cookie())
      :ok = Connections.record_application(Target, {:direct, Connections.node_app(name)})

      Target.disconnect()

      assert Connections.app() == nil
      assert :ok = Connections.check_application({:direct, "other"}, "other@host")
    end

    test "a record for an earlier node does not fix the application of a new one" do
      {_peer1, node1} = Fixture.start_peer()
      {_peer2, node2} = Fixture.start_peer()
      {:ok, _} = Target.connect(Atom.to_string(node1), Fixture.cookie())

      :ok =
        Connections.record_application(
          Target,
          {:direct, Connections.node_app(Atom.to_string(node1))}
        )

      Target.disconnect()
      {:ok, _} = Target.connect(Atom.to_string(node2), Fixture.cookie())

      assert Connections.app() == nil
    end

    test "with multiple connections off, any application may connect" do
      {_peer, node} = Fixture.start_peer()
      name = Atom.to_string(node)
      {:ok, _} = Target.connect(name, Fixture.cookie())
      :ok = Connections.record_application(Target, {:direct, Connections.node_app(name)})
      :ok = Settings.put_multiple_connections(false)

      assert :ok = Connections.check_application({:direct, "other"}, "other@host")
    end
  end
end
