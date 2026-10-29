defmodule Beamdash.TargetTest do
  use ExUnit.Case, async: false

  alias Beamdash.Target

  @cookie "beamdash_test_cookie"

  setup do
    # :standard_io keeps the peer from auto-connecting to us, so the
    # test sees only the connection that Target makes.
    {:ok, peer, node} =
      :peer.start(%{
        name: :peer.random_name(),
        args: [~c"-setcookie", String.to_charlist(@cookie)],
        connection: :standard_io
      })

    server = start_supervised!({Target, name: :"target_#{System.unique_integer([:positive])}"})

    on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        _, _ -> :ok
      end
    end)

    %{peer: peer, node: node, server: server}
  end

  test "connects as a hidden node, loads the agent and lists processes", ctx do
    assert {:ok, info} = Target.connect(Atom.to_string(ctx.node), @cookie, ctx.server)
    assert info.node == ctx.node
    assert info.agent_version == 21

    assert ctx.node in Node.list(:hidden)
    refute ctx.node in Node.list(:visible)

    assert {:ok, procs} = Target.processes(ctx.server)
    assert length(procs) > 10
    assert Enum.any?(procs, &(&1.registered_name == :code_server))

    # proc_lib processes report their real entry point, not proc_lib:init_p/5
    assert %{initial_call: {:supervisor, :kernel, 1}} =
             Enum.find(procs, &(&1.registered_name == :kernel_sup))

    refute Enum.any?(procs, &match?(%{initial_call: {:proc_lib, :init_p, 5}}, &1))
  end

  test "reconnecting does not reload an unchanged agent", ctx do
    assert {:ok, _} = Target.connect(Atom.to_string(ctx.node), @cookie, ctx.server)
    assert :ok = Target.disconnect(ctx.server)
    assert {:ok, _} = Target.connect(Atom.to_string(ctx.node), @cookie, ctx.server)
    assert %{status: :connected} = Target.status(ctx.server)
  end

  test "source/1 is nil, :direct once connected, and nil after disconnect", ctx do
    assert Target.source(ctx.server) == nil
    assert {:ok, _} = Target.connect(Atom.to_string(ctx.node), @cookie, ctx.server)
    assert Target.source(ctx.server) == :direct
    assert :ok = Target.disconnect(ctx.server)
    assert Target.source(ctx.server) == nil
  end

  test "a wrong cookie is reported", ctx do
    assert {:error, :connect_failed} =
             Target.connect(Atom.to_string(ctx.node), "wrong", ctx.server)

    assert %{status: :disconnected} = Target.status(ctx.server)
  end

  test "subscribers hear when the target goes down", ctx do
    :ok = Target.subscribe(ctx.server)
    assert {:ok, _} = Target.connect(Atom.to_string(ctx.node), @cookie, ctx.server)
    assert_receive {:beamdash_target, {:connected, node}} when node == ctx.node

    :peer.stop(ctx.peer)

    assert_receive {:beamdash_target, {:disconnected, :nodedown}}, 5_000
    assert {:error, :not_connected} = Target.processes(ctx.server)
  end

  for {order, first_reason} <- [{:node_first, :nodedown}, {:port_first, :tunnel_failed}] do
    test "#{order}: late port exits do not crash the target or cancel reconnect", ctx do
      server = ctx.server
      :ok = Target.subscribe(server)
      assert {:ok, _} = Target.connect(Atom.to_string(ctx.node), @cookie, server)
      assert_receive {:beamdash_target, {:connected, _}}

      port1 =
        Port.open({:spawn_executable, System.find_executable("cat")}, [:binary, :exit_status])

      port2 =
        Port.open({:spawn_executable, System.find_executable("cat")}, [:binary, :exit_status])

      tunnel = %Beamdash.Kubectl.Tunnel{epmd_port: port1, dist_port: port2}

      :sys.replace_state(server, fn state ->
        %{state | tunnel: tunnel, auto_reconnect: fn -> true end, reconnect_delays: [60_000]}
      end)

      pid = GenServer.whereis(server)
      ref = Process.monitor(pid)

      case unquote(order) do
        :node_first -> send(pid, {:nodedown, ctx.node})
        :port_first -> send(pid, {port1, {:exit_status, 1}})
      end

      assert_receive {:beamdash_target, {:disconnected, unquote(first_reason)}}, 5_000
      assert %{node: node, attempt: 1} = Target.reconnecting(server)
      assert node == ctx.node
      send(pid, {port1, {:exit_status, 1}})
      send(pid, {port2, {:exit_status, 1}})
      send(pid, {:nodedown, ctx.node})
      assert %{status: :disconnected} = Target.status(server)
      assert %{node: ^node, attempt: 1} = Target.reconnecting(server)
      assert GenServer.whereis(server) == pid
      refute_receive {:DOWN, ^ref, :process, _, _}, 100
      refute_receive {:beamdash_target, {:disconnected, _}}, 100
    end
  end

  test "a stale port exit cannot disconnect a newer connection", ctx do
    assert {:ok, _} = Target.connect(Atom.to_string(ctx.node), @cookie, ctx.server)
    stale = Port.open({:spawn_executable, System.find_executable("cat")}, [:binary, :exit_status])
    Port.close(stale)
    pid = GenServer.whereis(ctx.server)
    send(pid, {stale, {:exit_status, 1}})
    assert %{status: :connected, node: node} = Target.status(ctx.server)
    assert node == ctx.node
    assert GenServer.whereis(ctx.server) == pid
  end

  test "a bare name gets this host appended" do
    {:ok, host} = :inet.gethostname()
    assert {:ok, node} = Target.parse_node("foo")
    assert node == :"foo@#{host}"
    assert {:error, :empty_node_name} = Target.parse_node("  ")
  end

  test "a target needing the other name mode restarts distribution automatically", ctx do
    # A dotted host picks long names; this one can't resolve, so the
    # connect itself fails, but distribution comes up in long names mode.
    assert {:error, _} = Target.connect("nonexistent@198.51.100.1", @cookie, ctx.server)
    assert Node.alive?()
    assert %{name_domain: :longnames} = :net_kernel.get_state()

    # ctx.node is a short name (started by :peer with no dots): connecting
    # to it must restart distribution in short names mode by itself,
    # exactly the scenario a kubectl pod (short, undotted hostname) hits
    # after an earlier dotted direct connect.
    assert {:ok, _} = Target.connect(Atom.to_string(ctx.node), @cookie, ctx.server)
    assert %{name_domain: :shortnames} = :net_kernel.get_state()
  end

  defp start_named_peer(name) do
    {:ok, peer, node} =
      :peer.start(%{
        name: name,
        args: [~c"-setcookie", String.to_charlist(@cookie)],
        connection: :standard_io
      })

    on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        _, _ -> :ok
      end
    end)

    {peer, node}
  end

  defp reconnecting_target(opts) do
    start_supervised!(
      {Target,
       [name: :"target_#{System.unique_integer([:positive])}", reconnect_delays: [100]] ++ opts},
      id: :reconnecting
    )
  end

  defp eventually(fun, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn -> fun.() || (Process.sleep(50) && nil) end)
    |> Enum.find(fn result ->
      result || (System.monotonic_time(:millisecond) > deadline and flunk("not in time"))
    end)
  end

  test "parse_pid: a pid's text, also one from before a reconnect", ctx do
    {:ok, _} = Target.connect(Atom.to_string(ctx.node), @cookie, ctx.server)
    {:ok, server} = Target.rpc(ctx.node, :erlang, :whereis, [:code_server])
    text = server |> :erlang.pid_to_list() |> List.to_string()

    assert Target.parse_pid(text, ctx.node) == server

    # the same process under a node index this VM no longer has, as in a
    # link made before the node was reconnected: list_to_pid refuses it
    [_, id, serial] = Regex.run(~r/^<\d+\.(\d+)\.(\d+)>$/, text)
    stale = "<99999.#{id}.#{serial}>"
    assert_raise ArgumentError, fn -> :erlang.list_to_pid(String.to_charlist(stale)) end
    assert Target.parse_pid(stale, ctx.node) == server

    # without an attached node it can't be rebuilt; other text isn't a pid
    assert Target.parse_pid(stale, nil) == nil

    for bad <- ["", "code_server", "<1.2>", "<a.b.c>", nil],
        do: assert(Target.parse_pid(bad, ctx.node) == nil)
  end

  describe "auto-reconnect" do
    test "a node that comes back is connected again" do
      name = :peer.random_name()
      {peer, node} = start_named_peer(name)
      server = reconnecting_target(auto_reconnect: fn -> true end)
      :ok = Target.subscribe(server)
      assert {:ok, _} = Target.connect(Atom.to_string(node), @cookie, server)
      assert_receive {:beamdash_target, {:connected, ^node}}

      :peer.stop(peer)
      assert_receive {:beamdash_target, {:disconnected, :nodedown}}, 5_000
      assert %{node: ^node, attempt: attempt} = Target.reconnecting(server)
      assert attempt >= 1

      # tries fail while it is away
      eventually(fn -> match?(%{attempt: n} when n >= 2, Target.reconnecting(server)) end)
      assert %{error: error} = Target.reconnecting(server)
      assert error != nil

      {_peer, ^node} = start_named_peer(name)
      assert_receive {:beamdash_target, {:connected, ^node}}, 10_000
      assert %{status: :connected, node: ^node} = Target.status(server)
      assert Target.reconnecting(server) == nil
      assert {:ok, _} = Target.processes(server)
    end

    test "off: a lost connection stays lost", ctx do
      server = reconnecting_target(auto_reconnect: fn -> false end)
      :ok = Target.subscribe(server)
      assert {:ok, _} = Target.connect(Atom.to_string(ctx.node), @cookie, server)

      :peer.stop(ctx.peer)
      assert_receive {:beamdash_target, {:disconnected, :nodedown}}, 5_000
      assert Target.reconnecting(server) == nil
    end

    test "Stop and Disconnect end the tries", ctx do
      server = reconnecting_target(auto_reconnect: fn -> true end)
      :ok = Target.subscribe(server)
      assert {:ok, _} = Target.connect(Atom.to_string(ctx.node), @cookie, server)

      :peer.stop(ctx.peer)
      assert_receive {:beamdash_target, {:disconnected, :nodedown}}, 5_000
      assert %{} = Target.reconnecting(server)
      assert :ok = Target.stop_reconnect(server)
      assert Target.reconnecting(server) == nil

      {peer, node} = start_named_peer(:peer.random_name())
      assert {:ok, _} = Target.connect(Atom.to_string(node), @cookie, server)
      :peer.stop(peer)
      assert_receive {:beamdash_target, {:disconnected, :nodedown}}, 5_000
      assert %{} = Target.reconnecting(server)
      assert :ok = Target.disconnect(server)
      assert Target.reconnecting(server) == nil
    end
  end

  describe "cluster nodes" do
    test "lists the attached node's connections and switches to one", ctx do
      {_peer, other} = start_named_peer(:peer.random_name())
      assert {:error, :not_connected} = Target.cluster_nodes(ctx.server)
      assert {:ok, _} = Target.connect(Atom.to_string(ctx.node), @cookie, ctx.server)
      true = :erpc.call(ctx.node, :net_kernel, :connect_node, [other])

      assert {:ok, %{this: this, visible: visible, hidden: hidden}} =
               Target.cluster_nodes(ctx.server)

      assert this == ctx.node
      assert visible == [other]
      refute node() in hidden

      assert {:ok, info} = Target.switch(other, ctx.server)
      assert info.node == other
      assert %{status: :connected, node: ^other} = Target.status(ctx.server)
      assert {:ok, %{this: ^other, visible: [back]}} = Target.cluster_nodes(ctx.server)
      assert back == ctx.node

      # the attached node itself: nothing changes
      assert {:ok, %{node: ^other}} = Target.switch(other, ctx.server)
    end
  end
end
