defmodule Exberly.OtpProcessTest do
  use ExUnit.Case, async: false

  alias Exberly.{OtpProcess, Record, Target}
  alias Exberly.Test.Fixture

  setup do
    {peer, node} = Fixture.start_peer()
    on_exit(fn -> Fixture.stop_peer(peer) end)

    # OtpProcess uses the application's Target
    case Target.status() do
      %{status: :connected} -> Target.disconnect()
      _ -> :ok
    end

    {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie())
    on_exit(fn -> Target.disconnect() end)
    :ok = Fixture.load(node)
    {:ok, _} = :erpc.call(node, :exberly_fixture, :start, [])
    %{node: node}
  end

  test "gen_server state, with the callback module's records named", ctx do
    pid = :erpc.call(ctx.node, :erlang, :whereis, [:exberly_fixture])
    1 = :erpc.call(ctx.node, :exberly_fixture, :bump, [])

    assert {:ok, %{module: :exberly_fixture, state: state}} = OtpProcess.state(pid)
    assert %Record{name: :st, fields: [count: 1, name: :fixture]} = state
  end

  test "a process that is not OTP times out; an exited one is noproc", ctx do
    pid = :erpc.call(ctx.node, :erlang, :spawn, [:timer, :sleep, [:infinity]])
    assert {:error, :timeout} = OtpProcess.state(pid)

    gone = :erpc.call(ctx.node, :erlang, :spawn, [:erlang, :now, []])
    Process.sleep(50)
    assert {:error, :noproc} = OtpProcess.state(gone)
  end

  test "supervision tree under kernel_sup", ctx do
    sup = :erpc.call(ctx.node, :erlang, :whereis, [:kernel_sup])
    assert {:ok, tree} = OtpProcess.tree(sup)

    assert %{id: :root, type: :supervisor, name: :kernel_sup, kind: :supervisor} = tree
    assert tree.strategy == :one_for_all

    logger_sup = Enum.find(tree.children, &(&1.id == :logger_sup))
    assert %{type: :supervisor, strategy: :one_for_one, children: [_ | _]} = logger_sup

    rex = Enum.find(tree.children, &(&1.id == :rex))
    assert %{type: :worker, kind: :gen_server, name: :rex, children: []} = rex
    assert is_pid(rex.pid)

    c = OtpProcess.counts(tree)
    assert c.supervisors >= 3 and c.workers >= 5
  end
end
