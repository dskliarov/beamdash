defmodule Beamdash.AgentTest do
  @moduledoc """
  The agent modules run inside the node being inspected, which may be a
  pure Erlang node, so they must not depend on Elixir at all. The peers
  started here have no Elixir code path, so every call below would fail
  with `undef` if they did.

  The expected values match what the original `erlyberly.erl` returned
  (checked side by side when it was ported to Elixir).
  """
  use ExUnit.Case, async: false

  alias Beamdash.Target
  alias Beamdash.Test.Fixture

  for agent <- [:erlyberly, :beamdash_agent] do
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

  # AgentLoader compiles the agent's abstract forms on the target, so the
  # agent must compile on OTP 25 too: no map comprehensions or generators
  # (OTP 26) and no `maybe` (OTP 25 only behind a feature flag). No OTP 25
  # install is available to test on, so this static check is the guard.
  test "beamdash_agent uses no OTP 26+ constructs" do
    {_, bin, _} = :code.get_object_code(:beamdash_agent)

    {:ok, {_, [abstract_code: {:raw_abstract_v1, forms}, imports: imports]}} =
      :beam_lib.chunks(bin, [:abstract_code, :imports])

    found =
      forms
      |> otp26_nodes([])
      |> Enum.uniq()

    assert found == []
    refute Enum.any?(imports, &match?({:erts_internal, :mc_iterator, _}, &1))
  end

  # map comprehensions and generators (OTP 26), maybe (OTP 27 without a
  # feature flag), strict generators (OTP 28)
  @otp26_nodes [
    :m_generate,
    :mc,
    :maybe,
    :maybe_match,
    :generate_strict,
    :b_generate_strict,
    :m_generate_strict
  ]

  defp otp26_nodes(term, acc) when is_tuple(term) and tuple_size(term) > 0 do
    acc =
      if elem(term, 0) in @otp26_nodes,
        do: [elem(term, 0) | acc],
        else: acc

    term |> Tuple.to_list() |> otp26_nodes(acc)
  end

  defp otp26_nodes([h | t], acc), do: otp26_nodes(t, otp26_nodes(h, acc))
  defp otp26_nodes(_, acc), do: acc

  describe "on a pure Erlang node" do
    setup do
      {peer, node} = Fixture.start_peer()
      on_exit(fn -> Fixture.stop_peer(peer) end)

      target = start_supervised!({Target, name: :"target_#{System.unique_integer([:positive])}"})
      {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie(), target)
      :ok = Fixture.load(node)
      {:ok, _} = :erpc.call(node, :beamdash_fixture, :start, [])

      # really no Elixir there
      assert :non_existing = :erpc.call(node, :code, :which, [Enum])
      %{node: node}
    end

    defp call(ctx, fun, args), do: :erpc.call(ctx.node, :erlyberly, fun, args, 60_000)

    test "records and process state", ctx do
      assert {:ok, [{:st, [:count, :name]}]} =
               call(ctx, :load_module_records, [:beamdash_fixture])

      assert {:ok, [{:handler, [:module, :id, :state, :supervised]}]} =
               call(ctx, :load_module_records, [:gen_event])

      pid = :erpc.call(ctx.node, :erlang, :whereis, [:beamdash_fixture])
      pid_string = :erpc.call(ctx.node, :erlang, :pid_to_list, [pid])

      assert {:ok,
              {:erlyberly_record, :st,
               [{:erlyberly_record_field, :count, 0}, {:erlyberly_record_field, :name, :fixture}]}} =
               call(ctx, :get_process_state, [pid_string])
    end

    test "source and abstract code", ctx do
      assert {:ok, "add(A, B) ->\n    A + B.\n"} =
               call(ctx, :get_source_code, [{:beamdash_fixture, :add, 2}])

      assert {:ok, source} = call(ctx, :get_source_code, [:beamdash_fixture])
      assert source =~ "-record(st,{count = 0, name = fixture})."

      assert {:ok, abstract} = call(ctx, :get_abstract_code, [{:beamdash_fixture, :add, 2}])
      assert abstract =~ "{function,"

      assert {:error, message} = call(ctx, :get_source_code, [:no_such_module])
      assert is_binary(message)
    end

    test "fun decompiler", ctx do
      fun = :erpc.call(ctx.node, :beamdash_fixture, :adder, [])
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

      assert {:beamdash_fixture, exports, _} =
               call(ctx, :module_functions, []) |> List.keyfind(:beamdash_fixture, 0)

      assert {:add, 2} in exports
    end

    test "process details: memory, GC, reductions and mailbox", ctx do
      pid = :erpc.call(ctx.node, :erlang, :whereis, [:beamdash_fixture])
      details = fn max -> :erpc.call(ctx.node, :beamdash_agent, :process_details, [pid, max]) end

      # hold the gen_server so casts pile up in its mailbox
      :ok = :erpc.call(ctx.node, :sys, :suspend, [pid])

      for i <- 1..5,
          do: :ok = :erpc.call(ctx.node, :gen_server, :cast, [pid, {:hello, i}])

      d = details.(10)
      assert d.registered_name == :beamdash_fixture
      assert d.initial_call == {:beamdash_fixture, :init, 1}
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
               :erpc.call(ctx.node, :beamdash_agent, :garbage_collect, [pid])

      assert is_integer(before) and is_integer(after_gc)
    end

    test "process details of a process that has exited", ctx do
      pid = :erpc.call(ctx.node, :erlang, :spawn, [:erlang, :now, []])
      Process.sleep(50)
      assert :undefined = :erpc.call(ctx.node, :beamdash_agent, :process_details, [pid, 10])
      assert :undefined = :erpc.call(ctx.node, :beamdash_agent, :garbage_collect, [pid])
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
      procs = :erpc.call(ctx.node, :beamdash_agent, :processes, [])
      kind = fn name -> Enum.find(procs, &(&1.registered_name == name)).kind end

      assert kind.(:beamdash_fixture) == :gen_server
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
      pid = :erpc.call(ctx.node, :erlang, :whereis, [:beamdash_fixture])
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

      assert cost.(fn -> :erpc.call(ctx.node, :beamdash_agent, :processes, []) end) <= per_call

      assert cost.(fn ->
               :erpc.call(ctx.node, :beamdash_agent, :process_details, [pid, 100])
             end) <= per_call
    end

    test "collectors report when they are not running", ctx do
      assert {:error, :tcollector_down} = call(ctx, :collect_trace_logs, [])
      assert {:error, :down} = call(ctx, :collect_seq_trace_logs, [])
    end
  end

  describe "log handler" do
    # Events are logged with Fixture.log/5, from a process whose group
    # leader is on the peer: the handler drops events whose group leader is
    # remote (as an erpc call's is), like the node's own console does.
    @describetag :capture_log

    setup do
      {peer, node} = Fixture.start_peer()
      on_exit(fn -> Fixture.stop_peer(peer) end)

      target = start_supervised!({Target, name: :"target_#{System.unique_integer([:positive])}"})
      {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie(), target)

      # really no Elixir there
      assert :non_existing = :erpc.call(node, :code, :which, [Enum])
      %{node: node}
    end

    defp handler_ids(node), do: :erpc.call(node, :logger, :get_handler_ids, [])

    defp wait_until(fun, deadline_ms \\ 2_000) do
      deadline = System.monotonic_time(:millisecond) + deadline_ms
      do_wait_until(fun, deadline)
    end

    defp do_wait_until(fun, deadline) do
      cond do
        fun.() ->
          true

        System.monotonic_time(:millisecond) > deadline ->
          false

        true ->
          Process.sleep(20)
          do_wait_until(fun, deadline)
      end
    end

    # receives batches until `total` entries plus dropped have arrived (or
    # the deadline passes); returns the batches oldest first
    defp collect_batches(total, timeout, acc \\ []) do
      seen = Enum.reduce(acc, 0, fn {entries, dropped}, n -> n + length(entries) + dropped end)

      if seen >= total do
        Enum.reverse(acc)
      else
        receive do
          {:beamdash_logs, entries, dropped} ->
            collect_batches(total, timeout, [{entries, dropped} | acc])
        after
          timeout -> Enum.reverse(acc)
        end
      end
    end

    test "streams a log event to the owner", %{node: node} do
      assert {:ok, level} = :erpc.call(node, :beamdash_agent, :log_attach, [self()])
      assert is_atom(level)
      assert :beamdash_logs in handler_ids(node)

      :ok = Fixture.log(node, :warning, "disk ~p% full", [91])

      assert_receive {:beamdash_logs, [entry], 0}, 2_000
      assert entry.level == :warning
      assert entry.msg == "disk 91% full"
      assert is_integer(entry.at)
      assert is_pid(entry.pid)
      assert node(entry.pid) == node
      assert is_list(entry.meta)
      refute List.keymember?(entry.meta, "time", 0)
      refute List.keymember?(entry.meta, "gl", 0)

      # metadata other than the well-known keys comes as text
      :ok = Fixture.log(node, :warning, "hi", [], %{request_id: {:req, 7}})
      assert_receive {:beamdash_logs, [entry], 0}, 2_000
      assert entry.msg == "hi"
      assert {"request_id", "{req,7}"} in entry.meta

      :ok = :erpc.call(node, :beamdash_agent, :log_detach, [])
    end

    test "events from a process with a remote group leader are dropped", %{node: node} do
      {:ok, _} = :erpc.call(node, :beamdash_agent, :log_attach, [self()])

      # erpc runs the call with this node's group leader
      :ok = :erpc.call(node, :logger, :warning, [~c"from rpc"])
      # a local event afterwards: once it is here the others would have been
      :ok = Fixture.log(node, :warning, "local")

      assert_receive {:beamdash_logs, entries, 0}, 2_000
      assert Enum.map(entries, & &1.msg) == ["local"]
      refute_receive {:beamdash_logs, _, _}, 400

      :ok = :erpc.call(node, :beamdash_agent, :log_detach, [])
    end

    test "progress reports are dropped, crash reports in the same domain kept", %{node: node} do
      :ok =
        Fixture.load_module(node, :beamdash_log_reports, ~S"""
        -module(beamdash_log_reports).
        -export([run/0]).
        cb(#{label := Label}) -> {"~p report", [Label]}.
        run() ->
            group_leader(whereis(user), self()),
            Meta = #{domain => [otp, sasl], report_cb => fun cb/1},
            logger:log(info, #{label => {supervisor, progress}, report => [{supervisor, x}]}, Meta),
            logger:log(error, #{label => {proc_lib, crash}, report => [[{pid, self()}], []]}, Meta).
        """)

      # progress reports are info level: let them reach the handler at all
      :ok = :erpc.call(node, :logger, :set_primary_config, [:level, :all])
      {:ok, :all} = :erpc.call(node, :beamdash_agent, :log_attach, [self()])

      try do
        :ok = :erpc.call(node, :beamdash_log_reports, :run, [])
        # a plain event afterwards: once it is here the others would have been
        :ok = Fixture.log(node, :warning, "local")

        entries = collect_batches(2, 2_000) |> Enum.flat_map(&elem(&1, 0))
        assert Enum.map(entries, & &1.msg) == ["{proc_lib,crash} report", "local"]
        assert [%{level: :error}, %{level: :warning}] = entries
        refute_receive {:beamdash_logs, _, _}, 400
      after
        :ok = :erpc.call(node, :logger, :set_primary_config, [:level, :notice])
        :ok = :erpc.call(node, :beamdash_agent, :log_detach, [])
      end
    end

    test "long messages are cut to 8 KB on a character boundary", %{node: node} do
      {:ok, _} = :erpc.call(node, :beamdash_agent, :log_attach, [self()])
      # 3-byte characters: 8192 is not a multiple of 3
      long = String.duplicate("€", 5_000)
      :ok = Fixture.log(node, :warning, "~ts", [long])

      assert_receive {:beamdash_logs, [entry], 0}, 2_000
      assert byte_size(entry.msg) <= 8_192
      assert byte_size(entry.msg) > 8_000
      assert String.valid?(entry.msg)
      :ok = :erpc.call(node, :beamdash_agent, :log_detach, [])
    end

    test "log_detach removes the handler and stops streaming", %{node: node} do
      {:ok, _} = :erpc.call(node, :beamdash_agent, :log_attach, [self()])
      assert :beamdash_logs in handler_ids(node)

      assert :ok = :erpc.call(node, :beamdash_agent, :log_detach, [])
      refute :beamdash_logs in handler_ids(node)
      assert :undefined = :erpc.call(node, :erlang, :whereis, [:beamdash_log_collector])

      :ok = Fixture.log(node, :warning, "after detach")
      refute_receive {:beamdash_logs, _, _}, 500

      # idempotent
      assert :ok = :erpc.call(node, :beamdash_agent, :log_detach, [])
    end

    test "attaching again re-points the collector at the new owner", %{node: node} do
      other = spawn(fn -> receive(do: (:stop -> :ok)) end)
      {:ok, _} = :erpc.call(node, :beamdash_agent, :log_attach, [other])
      collector = :erpc.call(node, :erlang, :whereis, [:beamdash_log_collector])

      {:ok, _} = :erpc.call(node, :beamdash_agent, :log_attach, [self()])
      assert collector == :erpc.call(node, :erlang, :whereis, [:beamdash_log_collector])
      assert [:beamdash_logs] == Enum.filter(handler_ids(node), &(&1 == :beamdash_logs))

      # the old owner going away no longer stops anything
      send(other, :stop)
      :ok = Fixture.log(node, :warning, "to the new owner")
      assert_receive {:beamdash_logs, [entry], 0}, 2_000
      assert entry.msg == "to the new owner"
      assert :beamdash_logs in handler_ids(node)

      :ok = :erpc.call(node, :beamdash_agent, :log_detach, [])
    end

    test "the handler goes away when the owner dies", %{node: node} do
      owner = spawn(fn -> receive(do: (:never -> :ok)) end)
      {:ok, _} = :erpc.call(node, :beamdash_agent, :log_attach, [owner])
      assert :beamdash_logs in handler_ids(node)

      Process.exit(owner, :kill)

      assert wait_until(fn -> :beamdash_logs not in handler_ids(node) end)

      assert wait_until(fn ->
               :erpc.call(node, :erlang, :whereis, [:beamdash_log_collector]) == :undefined
             end)
    end

    test "at most 500 entries per batch, the rest counted as dropped", %{node: node} do
      :ok =
        Fixture.load_module(node, :beamdash_log_burst, """
        -module(beamdash_log_burst).
        -export([run/1]).
        run(N) ->
            group_leader(whereis(user), self()),
            lists:foreach(fun(I) -> logger:info("burst ~p", [I]) end, lists:seq(1, N)).
        """)

      :ok = :erpc.call(node, :logger, :set_primary_config, [:level, :all])
      {:ok, :all} = :erpc.call(node, :beamdash_agent, :log_attach, [self()])
      :ok = :erpc.call(node, :beamdash_log_burst, :run, [600])

      batches = collect_batches(600, 5_000)
      entries = Enum.flat_map(batches, &elem(&1, 0))
      dropped = batches |> Enum.map(&elem(&1, 1)) |> Enum.sum()

      assert Enum.all?(batches, fn {es, _} -> length(es) <= 500 end)
      assert length(entries) + dropped == 600
      assert length(entries) <= 600
      assert dropped > 0 or length(entries) == 600
      assert Enum.all?(entries, &String.starts_with?(&1.msg, "burst "))
      # oldest first
      assert hd(entries).msg == "burst 1"

      :ok = :erpc.call(node, :beamdash_agent, :log_detach, [])
    end

    test "while the collector's buffer is full, log/2 only counts the event", %{node: node} do
      # sets the handler's "full" flag by hand, logs, clears it, logs again
      :ok =
        Fixture.load_module(node, :beamdash_log_full, ~S"""
        -module(beamdash_log_full).
        -export([run/0]).
        run() ->
            group_leader(whereis(user), self()),
            {ok, #{config := #{full := Full}}} = logger:get_handler_config(beamdash_logs),
            atomics:put(Full, 1, 1),
            logger:warning("skipped"),
            atomics:put(Full, 1, 0),
            logger:warning("kept").
        """)

      {:ok, _} = :erpc.call(node, :beamdash_agent, :log_attach, [self()])
      :ok = :erpc.call(node, :beamdash_log_full, :run, [])

      assert_receive {:beamdash_logs, [entry], 1}, 2_000
      assert entry.msg == "kept"
      refute_receive {:beamdash_logs, _, _}, 400

      :ok = :erpc.call(node, :beamdash_agent, :log_detach, [])
    end
  end

  describe "log handler on a busy distribution link" do
    @describetag :capture_log

    # beamdash's node (the owner) stops reading: here a second peer, stopped
    # with SIGSTOP, behind a link whose busy limit is 1 KB (+zdbbl 1)
    setup do
      {peer, node} = Fixture.start_peer([~c"+zdbbl", ~c"1"])
      {owner_peer, owner_node} = Fixture.start_peer()
      # Target loads the agent on the node
      target = start_supervised!({Target, name: :"target_#{System.unique_integer([:positive])}"})
      {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie(), target)
      true = peer_connect(owner_node)
      os_pid = :erpc.call(owner_node, :os, :getpid, [])

      on_exit(fn ->
        System.cmd("kill", ["-CONT", List.to_string(os_pid)])
        Fixture.stop_peer(peer)
        Fixture.stop_peer(owner_peer)
      end)

      true = :erpc.call(node, :net_kernel, :connect_node, [owner_node])
      # an owner that never reads its mailbox
      owner = :erpc.call(owner_node, :erlang, :spawn, [:timer, :sleep, [:infinity]])

      :ok =
        Fixture.load_module(node, :beamdash_log_wave, """
        -module(beamdash_log_wave).
        -export([run/2]).
        %% N events of about 8 KB each
        run(Tag, N) ->
            group_leader(whereis(user), self()),
            Pad = lists:duplicate(8000, $x),
            lists:foreach(fun(I) -> logger:warning("~s ~p ~s", [Tag, I, Pad]) end,
                          lists:seq(1, N)).
        """)

      %{node: node, owner_node: owner_node, owner: owner, os_pid: List.to_string(os_pid)}
    end

    defp peer_connect(node) do
      Node.set_cookie(node, String.to_atom(Fixture.cookie()))
      Node.connect(node)
    end

    # the peer's distribution port to `to` holds more than the busy limit
    defp link_busy?(node, to) do
      node
      |> :erpc.call(:erlang, :system_info, [:dist_ctrl])
      |> Enum.any?(fn
        {^to, port} when is_port(port) ->
          case :erpc.call(node, :erlang, :port_info, [port, :queue_size]) do
            {:queue_size, size} -> size > 1_024
            _ -> false
          end

        _ ->
          false
      end)
    end

    defp owner_batches(owner_node, owner) do
      {:messages, msgs} = :erpc.call(owner_node, :erlang, :process_info, [owner, :messages])
      for {:beamdash_logs, entries, dropped} <- msgs, do: {length(entries), dropped}
    end

    test "the collector drops batches instead of blocking, and counts them", ctx do
      %{node: node, owner_node: owner_node, owner: owner} = ctx
      {:ok, _} = :erpc.call(node, :beamdash_agent, :log_attach, [owner])
      collector = :erpc.call(node, :erlang, :whereis, [:beamdash_log_collector])

      System.cmd("kill", ["-STOP", ctx.os_pid])

      # The first batches fill the socket buffers, later ones find the link
      # busy. How much that takes depends on the OS (Linux loopback buffers
      # can hold megabytes), so log waves until the link is busy, then one
      # more that has to be dropped: at most 20 waves or 30 s. `total` is
      # what was really logged.
      deadline = System.monotonic_time(:millisecond) + 30_000

      {total, _} =
        Enum.reduce_while(1..20, {0, false}, fn wave, {total, was_busy?} ->
          :ok = :erpc.call(node, :beamdash_log_wave, :run, [~c"w#{wave}", 100], 10_000)
          Process.sleep(300)
          total = total + 100

          if was_busy? or System.monotonic_time(:millisecond) > deadline,
            do: {:halt, {total, true}},
            else: {:cont, {total, link_busy?(node, ctx.owner_node)}}
        end)

      # still running and taking messages, not suspended on the port
      info = :erpc.call(node, :erlang, :process_info, [collector, [:status, :message_queue_len]])
      assert info[:status] != :suspended
      assert info[:message_queue_len] < 50

      System.cmd("kill", ["-CONT", ctx.os_pid])

      # every event arrives as an entry or in a dropped count (a dropped
      # batch's count goes with a later send, retried until the link is free)
      assert wait_until(
               fn ->
                 batches = owner_batches(owner_node, owner)
                 Enum.sum(Enum.map(batches, fn {n, d} -> n + d end)) == total
               end,
               10_000
             )

      batches = owner_batches(owner_node, owner)
      assert Enum.sum(Enum.map(batches, &elem(&1, 1))) > 0

      # detaching does not wait on the link either
      {us, :ok} = :timer.tc(fn -> :erpc.call(node, :beamdash_agent, :log_detach, []) end)
      assert us < 2_000_000
    end
  end

  describe "log_send/3" do
    test "ok when sent, dropped when the message did not go out" do
      assert :ok = :beamdash_agent.log_send(self(), [], 3)
      assert_received {:beamdash_logs, [], 3}

      # an owner on a node that is gone: send returns noconnect (a busy
      # link's nosuspend is covered by the busy-link test above)
      {peer, node} = Fixture.start_peer()
      Node.set_cookie(node, String.to_atom(Fixture.cookie()))
      true = Node.connect(node)
      remote = :erpc.call(node, :erlang, :spawn, [:timer, :sleep, [:infinity]])
      Fixture.stop_peer(peer)
      # the connection may take a moment to go down; a send over it is ok
      assert wait_until(fn -> node not in (Node.list(:hidden) ++ Node.list()) end, 5_000)
      assert :dropped = :beamdash_agent.log_send(remote, [], 0)
    end
  end
end
