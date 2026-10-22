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
    assert info.agent_version == 14

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
end
