defmodule Exberly.SysTracerTest do
  use ExUnit.Case, async: false

  alias Exberly.{SysEvent, SysTracer, Target}
  alias Exberly.Test.Fixture

  setup do
    {peer, node} = Fixture.start_peer()
    on_exit(fn -> Fixture.stop_peer(peer) end)

    id = System.unique_integer([:positive])
    target = start_supervised!({Target, name: :"target_#{id}"}, id: :target)
    sys = start_supervised!({SysTracer, name: :"sys_#{id}", target: target}, id: :sys)

    {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie(), target)
    :ok = Fixture.load(node)
    {:ok, server} = :erpc.call(node, :exberly_fixture, :start, [])
    :ok = SysTracer.subscribe(sys)

    %{node: node, target: target, sys: sys, server: server}
  end

  # The debug options a sys-compliant process runs with, from
  # sys:get_status/1: {trace, true} and installed functions show up there.
  defp debug(ctx, pid) do
    {:status, _, _, [_pdict, _sys_state, _parent, dbg | _]} =
      :erpc.call(ctx.node, :sys, :get_status, [pid])

    dbg
  end

  defp traced?(dbg), do: {:trace, true} in dbg
  defp installed?(dbg), do: List.keymember?(dbg, :exberly, 0)

  defp events(pid, timeout \\ 2_000) do
    receive do
      {:exberly_sys_trace, ^pid, {:events, evs}} -> evs
    after
      timeout -> flunk("no sys:trace events")
    end
  end

  # Whatever else arrives within half a second.
  defp more_events(pid) do
    receive do
      {:exberly_sys_trace, ^pid, {:events, evs}} -> evs ++ more_events(pid)
    after
      500 -> []
    end
  end

  test "sys:trace on a gen_server: switched on, events arrive, switched off", ctx do
    pid = ctx.server
    refute traced?(debug(ctx, pid))

    assert :ok = SysTracer.enable(pid, ctx.sys)
    assert_receive {:exberly_sys_trace, ^pid, :enabled}
    assert [^pid] = SysTracer.traced(ctx.sys)
    dbg = debug(ctx, pid)
    assert traced?(dbg) and installed?(dbg)

    assert 1 = :erpc.call(ctx.node, :exberly_fixture, :bump, [])
    :ok = :erpc.call(ctx.node, :gen_server, :cast, [pid, :hello])

    evs = events(pid) ++ more_events(pid)
    described = Enum.map(evs, &SysEvent.describe(&1.event, :erlang))

    assert {"call", "got call bump from " <> _} = Enum.at(described, 0)
    assert {"reply", "sent 1 to " <> rest} = Enum.at(described, 1)
    assert rest =~ "new state {st,1,fixture}"
    assert {"cast", "got cast hello"} in described
    assert Enum.all?(evs, &is_integer(&1.at_us))

    assert %{events: kept, dropped: 0} = SysTracer.info(pid, ctx.sys)
    assert length(kept) == length(evs)

    assert :ok = SysTracer.disable(pid, ctx.sys)
    assert_receive {:exberly_sys_trace, ^pid, :disabled}
    dbg = debug(ctx, pid)
    refute traced?(dbg) or installed?(dbg)
    assert [] = SysTracer.traced(ctx.sys)
    assert nil == SysTracer.info(pid, ctx.sys)
  end

  test "gen_statem events are described as sys:trace prints them", ctx do
    :ok =
      Fixture.load_module(ctx.node, :fixture_statem, """
      -module(fixture_statem).
      -export([init/1, callback_mode/0, idle/3]).
      init([]) -> {ok, idle, 0}.
      callback_mode() -> state_functions.
      idle({call, From}, go, N) -> {next_state, busy, N + 1, [{reply, From, ok}]};
      idle(cast, _, N) -> {keep_state, N}.
      """)

    {:ok, pid} = :erpc.call(ctx.node, :gen_statem, :start, [:fixture_statem, [], []])
    assert :ok = SysTracer.enable(pid, ctx.sys)
    assert :ok = :erpc.call(ctx.node, :gen_statem, :call, [pid, :go])

    described =
      events(pid) |> Enum.map(&SysEvent.describe(&1.event, :erlang)) |> Enum.map(&elem(&1, 1))

    assert Enum.any?(described, &(&1 =~ ~r/^receive call go from <.*> in state idle$/))
    assert Enum.any?(described, &(&1 =~ ~r/^send ok to </))
    assert Enum.any?(described, &(&1 =~ ~r/^consume call go from .* in state idle → busy$/))
  end

  test "a traced process that exits is reported", ctx do
    pid = ctx.server
    assert :ok = SysTracer.enable(pid, ctx.sys)
    :erpc.call(ctx.node, :erlang, :exit, [pid, :kill])
    assert_receive {:exberly_sys_trace, ^pid, {:exited, :killed}}, 2_000
    assert %{exited: :killed} = SysTracer.info(pid, ctx.sys)
  end

  test "tracing is switched off when exberly goes away", ctx do
    pid = ctx.server
    assert :ok = SysTracer.enable(pid, ctx.sys)
    assert traced?(debug(ctx, pid))

    # the SysTracer dying: the collector on the target cleans up
    :ok = stop_supervised(:sys)
    Process.sleep(300)
    dbg = debug(ctx, pid)
    refute traced?(dbg) or installed?(dbg)

    # and on disconnect
    sys = start_supervised!({SysTracer, name: :sys_again, target: ctx.target}, id: :sys2)
    assert :ok = SysTracer.enable(pid, sys)
    assert traced?(debug(ctx, pid))
    node = ctx.node
    :ok = Target.disconnect(ctx.target)
    Node.connect(node)
    Process.sleep(300)
    dbg = debug(ctx, pid)
    refute traced?(dbg) or installed?(dbg)
  end

  test "a process that does not answer sys requests times out cleanly", ctx do
    # a plain process: never answers system messages
    pid = :erpc.call(ctx.node, :erlang, :spawn, [:timer, :sleep, [:infinity]])
    assert {:error, :timeout} = SysTracer.enable(pid, ctx.sys)
    assert [] = SysTracer.traced(ctx.sys)
  end
end
