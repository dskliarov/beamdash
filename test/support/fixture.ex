defmodule Beamdash.Test.Fixture do
  @moduledoc false
  # Starts a peer node, connects beamdash's processes to it, and loads a
  # small gen_server module compiled with debug_info (so erlyberly can find
  # its records and xref can index it).

  @cookie "beamdash_test_cookie"

  @source """
  -module(beamdash_fixture).
  -behaviour(gen_server).
  -export([add/2, boom/1, spin/1, spin_notify/1, start/0, bump/0, total/1, adder/0]).
  -export([init/1, handle_call/3, handle_cast/2]).
  -record(st, {count = 0, name = fixture}).

  add(A, B) -> A + B.
  boom(X) -> erlang:error({boom, X}).
  spin(0) -> ok;
  spin(N) -> add(N, N), spin(N - 1).
  total(L) -> lists:foldl(fun add/2, 0, L).
  spin_notify(Pid) -> spin(1), Pid ! spun.
  adder() -> fun(X) -> X + 1 end.

  start() -> gen_server:start({local, ?MODULE}, ?MODULE, [], []).
  bump() -> gen_server:call(?MODULE, bump).

  init([]) -> {ok, #st{}}.
  handle_call(bump, _From, S = #st{count = C}) -> {reply, C + 1, S#st{count = C + 1}}.
  handle_cast(_Msg, S) -> {noreply, S}.
  """

  # Logs from a process whose group leader is on the peer itself. An erpc
  # call runs with the caller's group leader (on this node), and the
  # agent's handler drops such events (remote_gl), as the node's own
  # console handler does.
  @log_source """
  -module(beamdash_log_helper).
  -export([log/4]).

  log(Level, Format, Args, Meta) ->
      group_leader(whereis(user), self()),
      logger:log(Level, Format, Args, Meta).
  """

  def cookie, do: @cookie

  @doc "Starts a peer node; `extra_args` are added to its command line."
  def start_peer(extra_args \\ []) do
    {:ok, peer, node} =
      :peer.start(%{
        name: :peer.random_name(),
        args: [~c"-setcookie", String.to_charlist(@cookie) | extra_args],
        connection: :standard_io
      })

    {peer, node}
  end

  @doc """
  Logs on `node` from a process whose group leader is local there, as an
  application's own processes are. `format` is an Erlang format string.
  """
  def log(node, level, format, args \\ [], meta \\ %{}) do
    if :erpc.call(node, :code, :is_loaded, [:beamdash_log_helper]) == false,
      do: :ok = load_module(node, :beamdash_log_helper, @log_source)

    :erpc.call(node, :beamdash_log_helper, :log, [level, to_charlist(format), args, meta])
  end

  def stop_peer(peer) do
    :peer.stop(peer)
  catch
    _, _ -> :ok
  end

  @doc "Compile an Erlang module from source here and load it on `node`."
  def load_module(node, name, source) do
    dir = Path.join(System.tmp_dir!(), "beamdash_#{name}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    src = Path.join(dir, "#{name}.erl")
    File.write!(src, source)

    {:ok, ^name} =
      :compile.file(String.to_charlist(src), [:debug_info, outdir: String.to_charlist(dir)])

    true = :erpc.call(node, :code, :add_patha, [String.to_charlist(dir)])
    {:module, ^name} = :erpc.call(node, :code, :load_file, [name])
    :ok
  end

  def load(node) do
    dir = Path.join(System.tmp_dir!(), "beamdash_fixture_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    src = Path.join(dir, "beamdash_fixture.erl")
    File.write!(src, @source)

    {:ok, :beamdash_fixture} =
      :compile.file(String.to_charlist(src), [:debug_info, outdir: String.to_charlist(dir)])

    true = :erpc.call(node, :code, :add_patha, [String.to_charlist(dir)])
    {:module, _} = :erpc.call(node, :code, :load_file, [:beamdash_fixture])
    :ok
  end

  @doc "A process_details/2 result, as the GC panel receives it."
  def gc_detail(pid \\ self()) do
    %{
      pid: pid,
      registered_name: nil,
      initial_call: {:erlang, :apply, 2},
      current_function: {:gen_server, :loop, 7},
      status: :waiting,
      mailbox: %{length: 0, messages: [], limit: -1},
      memory: %{
        total: 100,
        heap: 60,
        total_heap: 80,
        stack: 10,
        binary_bytes: 0,
        binary_count: 0,
        message_queue_data: :on_heap
      },
      gc: %{
        minor_gcs: 1,
        fullsweep_after: 65_535,
        heap_block_size: 100,
        old_heap_size: 0,
        old_heap_block_size: 0,
        mbuf_size: 0,
        recent_size: 0,
        min_heap_size: 100,
        min_bin_vheap_size: 100,
        max_heap_size: :unlimited,
        bin_vheap_size: 0,
        bin_old_vheap_size: 0
      }
    }
  end

  @doc """
  Changes the Jev configuration for the calling test (an API key, or
  `enabled: false`) and restores it when the test ends.
  """
  def put_jev_config(changes) do
    previous = Application.get_env(:beamdash, Beamdash.Jev, [])
    Application.put_env(:beamdash, Beamdash.Jev, Keyword.merge(previous, changes))
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:beamdash, Beamdash.Jev, previous) end)
    :ok
  end
end
