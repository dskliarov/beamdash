defmodule Exberly.MemoryTest do
  use ExUnit.Case, async: false

  alias Exberly.{Memory, Target}
  alias Exberly.Test.Fixture

  setup do
    {peer, node} = Fixture.start_peer()
    on_exit(fn -> Fixture.stop_peer(peer) end)

    target = start_supervised!({Target, name: :"target_#{System.unique_integer([:positive])}"})
    {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie(), target)
    :ok = Fixture.load(node)

    # three leaks: a big heap, a process holding binaries it no longer
    # uses, a full ETS table (plain Erlang: no Elixir on the peer). The
    # holder gets two 100 KB binaries: together they stay under its binary
    # heap's first limit, so nothing collects them until we do.
    :ok =
      Fixture.load_module(node, :leaky, """
      -module(leaky).
      -export([start/0, hog/0, holder/0, owner/0]).
      start() ->
          register(hog, spawn(?MODULE, hog, [])),
          register(holder, spawn(?MODULE, holder, [])),
          register(table_owner, spawn(?MODULE, owner, [])),
          [holder ! {bin, binary:copy(<<1>>, 100000)} || _ <- lists:seq(1, 2)],
          [hog ! {msg, I} || I <- lists:seq(1, 300)],
          ok.
      hog() -> L = lists:seq(1, 200000), receive stop -> L end.
      holder() -> receive {bin, _} -> holder() end.
      owner() ->
          ets:new(leaky_table, [named_table, public]),
          [ets:insert(leaky_table, {I, lists:duplicate(20, I)}) || I <- lists:seq(1, 500)],
          receive stop -> ok end.
      """)

    :ok = :erpc.call(node, :leaky, :start, [])
    Process.sleep(200)
    %{node: node}
  end

  test "recon: the node has none, and here it is not fetched, so built-in", ctx do
    expected = if Code.ensure_loaded?(:recon), do: :loaded, else: :builtin
    assert Memory.recon_status(ctx.node) == expected
  end

  test "snapshot is erlang:memory() with limits", ctx do
    {:ok, snap} = Memory.snapshot(ctx.node)
    m = snap.memory
    assert m.total == m.processes + m.system
    assert m.binary >= 200_000
    assert snap.atom_count < snap.atom_limit
    assert snap.process_count > 10 and is_integer(snap.process_limit)
    assert snap.word_size in [4, 8]

    # with recon: what the VM has allocated from the OS (recon_alloc)
    if Memory.recon_status(ctx.node) != :builtin do
      {:ok, snap} = Memory.snapshot(ctx.node)
      assert snap.recon
      assert snap.alloc.allocated >= snap.alloc.used and snap.alloc.usage > 0
    end
  end

  test "top processes by memory, message queue and binary memory", ctx do
    # recon:proc_count/2 when exberly has recon (loaded into the node by
    # Memory.recon_status/1), else the built-in equivalent
    _ = Memory.recon_status(ctx.node)
    source = if Code.ensure_loaded?(:recon), do: :recon, else: :builtin
    {:ok, {^source, by_mem}} = Memory.top_processes(ctx.node, :memory, 3)
    assert %{name: :hog} = hd(by_mem)

    {:ok, {_src, by_queue}} = Memory.top_processes(ctx.node, :message_queue_len, 3)
    assert %{name: :hog, value: 300} = hd(by_queue)

    {:ok, {_src, by_bin}} = Memory.top_processes(ctx.node, :binary_memory, 3)
    assert %{name: :holder, value: 200_000} = hd(by_bin)
    assert {:leaky, :holder, 0} = hd(by_bin).initial_call
  end

  test "garbage collecting frees binaries held but no longer used", ctx do
    # (system processes release some too, so ask for more than a few)
    _ = Memory.recon_status(ctx.node)
    {:ok, leaks} = Memory.binary_leaks(ctx.node, 50)
    assert leaks.source == if(Code.ensure_loaded?(:recon), do: :recon, else: :builtin)
    # the holder's two binaries, freed by the collection
    assert leaks.binary_before - leaks.binary_after >= 200_000
    assert Enum.any?(leaks.processes, &(&1.name == :holder and &1.value == 2))

    # before/after of every kind (a collection can briefly raise the total:
    # a full sweep copies a big heap into a new block)
    {:ok, gc} = Memory.gc_all(ctx.node)

    for kind <- [:total, :processes, :binary],
        do: assert(is_integer(gc.before[kind]) and is_integer(gc.after[kind]))
  end

  test "ETS tables with owners and memory in bytes", ctx do
    {:ok, tables} = Memory.ets_tables(ctx.node)
    t = Enum.find(tables, &(&1.name == :leaky_table))
    assert %{named: true, size: 500, owner_name: :table_owner, type: :set} = t
    assert t.memory > 500 * 20
  end

  test "process state: stack, and sys:get_status on request", ctx do
    pid = :erpc.call(ctx.node, :erlang, :whereis, [:code_server])
    {:ok, s} = Memory.process_state(ctx.node, pid, false)
    assert s.status == :not_requested and s.stack != []

    # a gen_server answers sys:get_status
    pid = :erpc.call(ctx.node, :erlang, :whereis, [:application_controller])

    {:ok, %{status: {:ok, {:status, ^pid, {:module, :gen_server}, _}}}} =
      Memory.process_state(ctx.node, pid, true)

    # a plain process does not: timeout after 2 s
    pid = :erpc.call(ctx.node, :erlang, :whereis, [:hog])
    {:ok, %{status: {:error, :timeout}}} = Memory.process_state(ctx.node, pid, true)
  end
end
