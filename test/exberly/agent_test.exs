defmodule Exberly.AgentTest do
  @moduledoc """
  The agent modules run inside the node being inspected, which may be a
  pure Erlang node, so they must not depend on Elixir at all. The peers
  started here have no Elixir code path, so every call below would fail
  with `undef` if they did.

  The expected values match what the original `erlyberly.erl` returned
  (checked side by side when it was ported to Elixir).
  """
  use ExUnit.Case, async: false

  alias Exberly.Target
  alias Exberly.Test.Fixture

  for agent <- [:erlyberly, :exberly_agent] do
    test "#{agent} calls no Elixir modules" do
      {_, bin, _} = :code.get_object_code(unquote(agent))
      {:ok, {_, [imports: imports]}} = :beam_lib.chunks(bin, [:imports])

      elixir =
        for {mod, _f, _a} <- imports,
            String.starts_with?(Atom.to_string(mod), "Elixir."),
            uniq: true,
            do: mod

      assert elixir == []
    end
  end

  describe "on a pure Erlang node" do
    setup do
      {peer, node} = Fixture.start_peer()
      on_exit(fn -> Fixture.stop_peer(peer) end)

      target = start_supervised!({Target, name: :"target_#{System.unique_integer([:positive])}"})
      {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie(), target)
      :ok = Fixture.load(node)
      {:ok, _} = :erpc.call(node, :exberly_fixture, :start, [])

      # really no Elixir there
      assert :non_existing = :erpc.call(node, :code, :which, [Enum])
      %{node: node}
    end

    defp call(ctx, fun, args), do: :erpc.call(ctx.node, :erlyberly, fun, args, 60_000)

    test "records and process state", ctx do
      assert {:ok, [{:st, [:count, :name]}]} =
               call(ctx, :load_module_records, [:exberly_fixture])

      assert {:ok, [{:handler, [:module, :id, :state, :supervised]}]} =
               call(ctx, :load_module_records, [:gen_event])

      pid = :erpc.call(ctx.node, :erlang, :whereis, [:exberly_fixture])
      pid_string = :erpc.call(ctx.node, :erlang, :pid_to_list, [pid])

      assert {:ok,
              {:erlyberly_record, :st,
               [{:erlyberly_record_field, :count, 0}, {:erlyberly_record_field, :name, :fixture}]}} =
               call(ctx, :get_process_state, [pid_string])
    end

    test "source and abstract code", ctx do
      assert {:ok, "add(A, B) ->\n    A + B.\n"} =
               call(ctx, :get_source_code, [{:exberly_fixture, :add, 2}])

      assert {:ok, source} = call(ctx, :get_source_code, [:exberly_fixture])
      assert source =~ "-record(st,{count = 0, name = fixture})."

      assert {:ok, abstract} = call(ctx, :get_abstract_code, [{:exberly_fixture, :add, 2}])
      assert abstract =~ "{function,"

      assert {:error, message} = call(ctx, :get_source_code, [:no_such_module])
      assert is_binary(message)
    end

    test "fun decompiler", ctx do
      fun = :erpc.call(ctx.node, :exberly_fixture, :adder, [])
      assert ~c"fun (X) -> X + 1 end." = call(ctx, :saleyn_fun_src, [fun])
    end

    test "process info and module loading", ctx do
      procs = call(ctx, :process_info, [])
      code_server = Enum.find(procs, &(&1[:registered_name] == :code_server))
      assert is_list(code_server[:pid])
      # sizes are in bytes, not words
      assert rem(code_server[:heap_size], :erlang.system_info(:wordsize)) == 0

      assert {:module, :dets} = call(ctx, :try_load_module, [:dets])
      assert :ok = call(ctx, :try_load_module, [:dets])

      assert {:exberly_fixture, exports, _} =
               call(ctx, :module_functions, []) |> List.keyfind(:exberly_fixture, 0)

      assert {:add, 2} in exports
    end

    test "process details: memory, GC, reductions and mailbox", ctx do
      pid = :erpc.call(ctx.node, :erlang, :whereis, [:exberly_fixture])
      details = fn max -> :erpc.call(ctx.node, :exberly_agent, :process_details, [pid, max]) end

      # hold the gen_server so casts pile up in its mailbox
      :ok = :erpc.call(ctx.node, :sys, :suspend, [pid])

      for i <- 1..5,
          do: :ok = :erpc.call(ctx.node, :gen_server, :cast, [pid, {:hello, i}])

      d = details.(10)
      assert d.registered_name == :exberly_fixture
      assert d.initial_call == {:exberly_fixture, :init, 1}
      assert d.status in [:waiting, :runnable, :suspended]
      assert is_integer(d.reductions) and d.reductions > 0
      assert is_integer(d.sampled_at_us)

      assert %{length: 5, messages: messages} = d.mailbox
      assert messages == for(i <- 1..5, do: {:"$gen_cast", {:hello, i}})
      # above the limit only the count is fetched
      assert %{length: 5, messages: :not_fetched, limit: 3} = details.(3).mailbox

      # at most 100 messages are returned, oldest first
      for i <- 6..150, do: :ok = :erpc.call(ctx.node, :gen_server, :cast, [pid, {:hello, i}])
      assert %{length: 150, messages: first} = details.(1_000).mailbox
      assert length(first) == 100
      assert hd(first) == {:"$gen_cast", {:hello, 1}}

      word = :erpc.call(ctx.node, :erlang, :system_info, [:wordsize])
      assert d.memory.total > 0
      assert rem(d.memory.heap, word) == 0 and d.memory.heap > 0
      assert d.memory.total_heap >= d.memory.heap
      assert is_integer(d.memory.binary_count) and is_integer(d.memory.binary_bytes)
      assert d.memory.message_queue_data in [:on_heap, :off_heap]

      assert is_integer(d.gc.minor_gcs)
      assert is_integer(d.gc.fullsweep_after)
      assert d.gc.min_heap_size > 0
      assert is_integer(d.gc.heap_block_size)
      assert d.gc.max_heap_size == :unlimited

      :ok = :erpc.call(ctx.node, :sys, :resume, [pid])

      assert %{before: before, after: after_gc} =
               :erpc.call(ctx.node, :exberly_agent, :garbage_collect, [pid])

      assert is_integer(before) and is_integer(after_gc)
    end

    test "process details of a process that has exited", ctx do
      pid = :erpc.call(ctx.node, :erlang, :spawn, [:erlang, :now, []])
      Process.sleep(50)
      assert :undefined = :erpc.call(ctx.node, :exberly_agent, :process_details, [pid, 10])
      assert :undefined = :erpc.call(ctx.node, :exberly_agent, :garbage_collect, [pid])
    end

    test "processes are classified by OTP behaviour", ctx do
      # an Elixir GenServer declares the 'Elixir.GenServer' behaviour
      :ok =
        Fixture.load_module(ctx.node, :ex_style_server, """
        -module(ex_style_server).
        -behaviour('Elixir.GenServer').
        -export([init/1, handle_call/3, handle_cast/2]).
        init([]) -> {ok, nil}.
        handle_call(_, _, S) -> {reply, ok, S}.
        handle_cast(_, S) -> {noreply, S}.
        """)

      # a gen_server whose module declares no behaviour at all
      :ok =
        Fixture.load_module(ctx.node, :undeclared_server, """
        -module(undeclared_server).
        -export([init/1, handle_call/3, handle_cast/2]).
        init([]) -> {ok, nil}.
        handle_call(_, _, S) -> {reply, ok, S}.
        handle_cast(_, S) -> {noreply, S}.
        """)

      for mod <- [:ex_style_server, :undeclared_server] do
        {:ok, _} = :erpc.call(ctx.node, :gen_server, :start, [{:local, mod}, mod, [], []])
      end

      # gen_statems: one declaring the behaviour, one (as Elixir modules
      # using `@behaviour :gen_statem` look the same) without it
      for {mod, attr} <- [statem_declared: "-behaviour(gen_statem).\n", statem_undeclared: ""] do
        :ok =
          Fixture.load_module(ctx.node, mod, """
          -module(#{mod}).
          #{attr}-export([init/1, callback_mode/0, idle/3]).
          init([]) -> {ok, idle, 0}.
          callback_mode() -> state_functions.
          idle(_, _, D) -> {keep_state, D}.
          """)

        {:ok, _} = :erpc.call(ctx.node, :gen_statem, :start, [{:local, mod}, mod, [], []])
      end

      Process.sleep(50)
      procs = :erpc.call(ctx.node, :exberly_agent, :processes, [])
      kind = fn name -> Enum.find(procs, &(&1.registered_name == name)).kind end

      assert kind.(:exberly_fixture) == :gen_server
      assert kind.(:ex_style_server) == :gen_server
      assert kind.(:undeclared_server) == :gen_server
      assert kind.(:statem_declared) == :gen_statem
      assert kind.(:statem_undeclared) == :gen_statem
      assert kind.(:kernel_sup) == :supervisor
      assert kind.(:standard_error_sup) == :supervisor
      assert kind.(:erl_signal_server) == :gen_event
      assert kind.(:code_server) == nil
      assert kind.(:init) == nil
    end

    test "looking at a process costs it as little as possible", ctx do
      # process_info on another process is a signal that process handles
      # itself, about one reduction each; an idle gen_server must not be
      # made to look busy by watching it.
      pid = :erpc.call(ctx.node, :erlang, :whereis, [:exberly_fixture])
      reds = fn -> elem(:erpc.call(ctx.node, :erlang, :process_info, [pid, :reductions]), 1) end
      otp = :erpc.call(ctx.node, :erlang, :system_info, [:otp_release]) |> List.to_integer()
      # before OTP 26 a proc_lib process's initial call needs a second call
      per_call = if otp >= 26, do: 1, else: 2

      cost = fn f ->
        # the measuring call itself costs one
        before = reds.()
        for _ <- 1..10, do: f.()
        (reds.() - before - 1) / 10
      end

      assert cost.(fn -> :erpc.call(ctx.node, :exberly_agent, :processes, []) end) <= per_call

      assert cost.(fn ->
               :erpc.call(ctx.node, :exberly_agent, :process_details, [pid, 100])
             end) <= per_call
    end

    test "collectors report when they are not running", ctx do
      assert {:error, :tcollector_down} = call(ctx, :collect_trace_logs, [])
      assert {:error, :down} = call(ctx, :collect_seq_trace_logs, [])
    end
  end
end
