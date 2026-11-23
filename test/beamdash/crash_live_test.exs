defmodule Beamdash.CrashLiveTest do
  use ExUnit.Case, async: false

  alias Beamdash.{Connections, Crashes, Settings, Target}
  alias Beamdash.Test.Fixture
  alias BeamdashWeb.CrashLive

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

  test "the crashes page reads its session's connection, and stops and starts that node's run" do
    {_peer1, node1} = Fixture.start_peer()
    {_peer2, node2} = Fixture.start_peer()
    {:ok, _} = Target.connect(Atom.to_string(node1), Fixture.cookie())
    extra = Connections.target_for_connect()
    {:ok, _} = Target.connect(Atom.to_string(node2), Fixture.cookie(), extra)

    socket =
      Fixture.with_conn(%Phoenix.LiveView.Socket{})
      |> Phoenix.Component.assign(:conn, %{server: extra})

    {:ok, s} = CrashLive.mount(%{}, %{}, socket)
    assert s.assigns.crashes == Connections.service(extra, Crashes)
    refute s.assigns.crashes == Crashes

    {:noreply, s} = CrashLive.handle_event("stop_run", %{}, s)
    assert s.assigns.crashes == nil
    assert Connections.service(extra, Crashes) == nil
    assert Process.alive?(Process.whereis(Crashes))

    {:noreply, s} = CrashLive.handle_event("start_run", %{}, s)
    assert is_pid(s.assigns.crashes)
    assert s.assigns.crashes == Connections.service(extra, Crashes)
  end
end
