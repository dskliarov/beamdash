defmodule Exberly.Milestone4Test do
  use ExUnit.Case, async: false

  alias Exberly.{CallGraph, Crashes, Record, SeqTracer, Target, Tracer}
  alias Exberly.Test.Fixture

  setup do
    {peer, node} = Fixture.start_peer()
    on_exit(fn -> Fixture.stop_peer(peer) end)

    id = System.unique_integer([:positive])
    target = start_supervised!({Target, name: :"target_#{id}"}, id: :target)
    tracer = start_supervised!({Tracer, name: :"tracer_#{id}", target: target}, id: :tracer)

    seq =
      start_supervised!({SeqTracer, name: :"seq_#{id}", target: target, tracer: tracer},
        id: :seq
      )

    crashes = start_supervised!({Crashes, name: :"crashes_#{id}", target: target}, id: :crashes)

    {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie(), target)
    :ok = Fixture.load(node)

    %{peer: peer, node: node, target: target, seq: seq, crashes: crashes}
  end

  describe "seq_trace" do
    test "follows the messages a call causes, across processes", ctx do
      {:ok, _} = :erpc.call(ctx.node, :exberly_fixture, :start, [])
      :ok = SeqTracer.subscribe(ctx.seq)
      assert :ok = SeqTracer.start(:exberly_fixture, :bump, 0, ctx.seq)
      assert [{:exberly_fixture, :bump, 0}] = SeqTracer.traces(ctx.seq)

      assert 1 = :erpc.call(ctx.node, :exberly_fixture, :bump, [])
      :ok = SeqTracer.poll(ctx.seq)

      assert_receive {:exberly_seq, {:events, events}}, 2_000
      sends = Enum.filter(events, &(&1.type == :send))

      # the caller's gen_server:call to the server ...
      assert Enum.any?(sends, fn e ->
               e.to == "exberly_fixture" and match?({:"$gen_call", _, :bump}, e.message)
             end)

      # ... and the server's reply, shown going back to the caller (it is
      # really sent to a process alias)
      [call] = Enum.filter(sends, &(&1.to == "exberly_fixture"))

      reply =
        Enum.find(sends, fn e -> e.from == "exberly_fixture" and match?({_, 1}, e.message) end)

      assert reply.to == call.from

      assert Enum.all?(events, &is_integer(&1.timestamp_us))
    end

    test "catches local calls from inside the module too", ctx do
      :ok = SeqTracer.subscribe(ctx.seq)
      # spin/1 calls add/2 locally
      :ok = SeqTracer.start(:exberly_fixture, :add, 2, ctx.seq)
      # spin_notify/1 calls spin/1, which calls add/2 locally; the message
      # sent afterwards carries the token
      :spun = :erpc.call(ctx.node, :exberly_fixture, :spin_notify, [self()])
      assert_receive :spun, 2_000
      :ok = SeqTracer.poll(ctx.seq)
      assert_receive {:exberly_seq, {:events, [_ | _]}}, 2_000
    end

    test "stop removes the pattern", ctx do
      {:ok, _} = :erpc.call(ctx.node, :exberly_fixture, :start, [])
      :ok = SeqTracer.start(:exberly_fixture, :bump, 0, ctx.seq)
      :ok = SeqTracer.stop(:exberly_fixture, :bump, 0, ctx.seq)
      assert [] = SeqTracer.traces(ctx.seq)
      :ok = SeqTracer.clear(ctx.seq)

      :erpc.call(ctx.node, :exberly_fixture, :bump, [])
      :ok = SeqTracer.poll(ctx.seq)
      assert [] = SeqTracer.events(ctx.seq)
    end
  end

  describe "call graph" do
    test "returns what a function calls; calls into OTP are leaves", ctx do
      assert {:ok, tree} = CallGraph.analyse(ctx.node, :exberly_fixture, :total, 1)
      assert tree.mfa == {:exberly_fixture, :total, 1}
      callees = Enum.map(tree.calls, & &1.mfa)
      assert {:lists, :foldl, 3} in callees
      assert %{calls: []} = Enum.find(tree.calls, &(&1.mfa == {:lists, :foldl, 3}))
    end

    test "recursion is not followed and depth is limited", ctx do
      assert {:ok, tree} = CallGraph.analyse(ctx.node, :exberly_fixture, :spin, 1)
      assert [%{mfa: {:exberly_fixture, :add, 2}, calls: []}] = tree.calls

      assert {:ok, %{calls: :more}} =
               CallGraph.analyse(ctx.node, :exberly_fixture, :spin, 1, max_depth: 0)
    end

    test "the index is built once and reused", ctx do
      assert :ok = CallGraph.index(ctx.node)
      {:ok, pid} = Target.rpc(ctx.node, :erlang, :whereis, [:erlyberly_xref])
      assert :ok = CallGraph.index(ctx.node)
      assert {:ok, ^pid} = Target.rpc(ctx.node, :erlang, :whereis, [:erlyberly_xref])
    end
  end

  describe "crash reports" do
    @tag :capture_log
    test "a crashing gen_server is reported with its reason and stack", ctx do
      :ok = Crashes.subscribe(ctx.crashes)
      {:ok, _} = :erpc.call(ctx.node, :exberly_fixture, :start, [])

      # an unknown call makes the gen_server crash
      catch_exit(:erpc.call(ctx.node, :gen_server, :call, [:exberly_fixture, :nope]))

      assert_receive {:exberly_crash, crash}, 5_000
      assert crash.registered_name == :exberly_fixture
      assert crash.class == :error
      assert crash.reason == :function_clause
      assert Enum.any?(crash.stack, &match?({:exberly_fixture, :handle_call, _, _}, &1))
      assert [^crash] = Crashes.reports(ctx.crashes)
    end

    test "disconnecting removes the handler from the target", ctx do
      assert {:ok, handlers} = Target.rpc(ctx.node, :gen_event, :which_handlers, [:error_logger])
      assert :erlyberly in handlers

      :ok = Target.disconnect(ctx.target)
      {:ok, _} = Target.connect(Atom.to_string(ctx.node), Fixture.cookie(), ctx.target)
      # reconnecting installs exactly one fresh handler
      Process.sleep(100)
      {:ok, handlers} = Target.rpc(ctx.node, :gen_event, :which_handlers, [:error_logger])
      assert Enum.count(handlers, &(&1 == :erlyberly)) == 1
    end
  end

  test "gen_server state prints as an Erlang record in Erlang syntax" do
    rec =
      Record.decode(
        {:erlyberly_record, :st,
         [{:erlyberly_record_field, :count, 1}, {:erlyberly_record_field, :name, :fixture}]}
      )

    assert Exberly.Format.term({:reply, :ok, rec}, :erlang) ==
             "{reply,ok,#st{count = 1,name = fixture}}"

    assert Exberly.Format.term({:reply, :ok, rec}, :elixir) ==
             "{:reply, :ok, #st{count: 1, name: :fixture}}"
  end
end
