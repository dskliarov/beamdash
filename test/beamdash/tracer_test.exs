defmodule Beamdash.TracerTest do
  use ExUnit.Case, async: false

  alias Beamdash.{Record, Target, Tracer}

  @cookie "beamdash_test_cookie"

  @fixture """
  -module(beamdash_fixture).
  -behaviour(gen_server).
  -export([add/2, boom/1, spin/1, start/0, bump/0]).
  -export([init/1, handle_call/3, handle_cast/2]).
  -record(st, {count = 0, name = fixture}).

  add(A, B) -> A + B.
  boom(X) -> erlang:error({boom, X}).
  spin(0) -> ok;
  spin(N) -> add(N, N), spin(N - 1).

  start() -> gen_server:start({local, ?MODULE}, ?MODULE, [], []).
  bump() -> gen_server:call(?MODULE, bump).

  init([]) -> {ok, #st{}}.
  handle_call(bump, _From, S = #st{count = C}) -> {reply, C + 1, S#st{count = C + 1}}.
  handle_cast(_Msg, S) -> {noreply, S}.
  """

  setup do
    {:ok, peer, node} =
      :peer.start(%{
        name: :peer.random_name(),
        args: [~c"-setcookie", String.to_charlist(@cookie)],
        connection: :standard_io
      })

    id = System.unique_integer([:positive])
    target = start_supervised!({Target, name: :"target_#{id}"}, id: :target)
    tracer = start_supervised!({Tracer, name: :"tracer_#{id}", target: target}, id: :tracer)

    on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        _, _ -> :ok
      end
    end)

    {:ok, _} = Target.connect(Atom.to_string(node), @cookie, target)
    :ok = Tracer.subscribe(tracer)
    load_fixture(node)

    %{peer: peer, node: node, target: target, tracer: tracer}
  end

  # Compile the fixture with debug_info into a directory the target can read,
  # so erlyberly can find its record definitions.
  defp load_fixture(node) do
    dir = Path.join(System.tmp_dir!(), "beamdash_fixture_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    src = Path.join(dir, "beamdash_fixture.erl")
    File.write!(src, @fixture)

    {:ok, :beamdash_fixture} =
      :compile.file(String.to_charlist(src), [:debug_info, outdir: String.to_charlist(dir)])

    true = :erpc.call(node, :code, :add_patha, [String.to_charlist(dir)])
    {:module, _} = :erpc.call(node, :code, :load_file, [:beamdash_fixture])
  end

  defp flush do
    receive do
      {:beamdash_trace, _} -> flush()
    after
      0 -> :ok
    end
  end

  defp next_completed_entry do
    receive do
      {:beamdash_trace, {:entry, %{result: :pending}}} -> next_completed_entry()
      {:beamdash_trace, {:entry, entry}} -> entry
    after
      5_000 -> flunk("no completed trace entry")
    end
  end

  test "traces a call and pairs it with its return", ctx do
    assert :ok = Tracer.start_trace(:beamdash_fixture, :add, 2, ctx.tracer)
    assert [{:beamdash_fixture, :add, 2}] = Tracer.traces(ctx.tracer)

    assert 5 = :erpc.call(ctx.node, :beamdash_fixture, :add, [2, 3])

    entry = next_completed_entry()

    assert %{mod: :beamdash_fixture, fun: :add, arity: 2, args: [2, 3], result: {:return, 5}} =
             entry

    assert is_integer(entry.call_us) and entry.return_us >= entry.call_us
    assert [^entry] = Tracer.entries(ctx.tracer)
  end

  test "records exceptions", ctx do
    :ok = Tracer.start_trace(:beamdash_fixture, :boom, 1, ctx.tracer)

    assert {:exception, :error, {:boom, :x}, _} =
             (try do
                :erpc.call(ctx.node, :beamdash_fixture, :boom, [:x])
              catch
                :error, {:exception, reason, stack} -> {:exception, :error, reason, stack}
              end)

    assert %{fun: :boom, args: [:x], result: {:exception, {:error, {:boom, :x}}}} =
             next_completed_entry()
  end

  test "shows gen_server state as a record", ctx do
    {:ok, _} = :erpc.call(ctx.node, :beamdash_fixture, :start, [])
    :ok = Tracer.start_trace(:beamdash_fixture, :handle_call, 3, ctx.tracer)

    assert 1 = :erpc.call(ctx.node, :beamdash_fixture, :bump, [])

    entry = next_completed_entry()
    assert [:bump, _from, %Record{name: :st, fields: [count: 0, name: :fixture]}] = entry.args

    assert {:return, {:reply, 1, %Record{name: :st, fields: [count: 1, name: :fixture]}}} =
             entry.result

    assert inspect(Enum.at(entry.args, 2)) == "#st{count: 0, name: :fixture}"
  end

  test "stop_trace stops new entries", ctx do
    :ok = Tracer.start_trace(:beamdash_fixture, :add, 2, ctx.tracer)
    :ok = Tracer.stop_trace(:beamdash_fixture, :add, 2, ctx.tracer)
    assert [] = Tracer.traces(ctx.tracer)

    :erpc.call(ctx.node, :beamdash_fixture, :add, [1, 1])
    refute_receive {:beamdash_trace, {:entry, _}}, 300
  end

  test "lists loaded modules with their functions", ctx do
    assert {:ok, mods} = Tracer.module_functions(ctx.tracer)
    assert {:beamdash_fixture, exports, _locals} = List.keyfind(mods, :beamdash_fixture, 0)
    assert {:add, 2} in exports
  end

  test "traces survive a hot code reload", ctx do
    :ok = Tracer.start_trace(:beamdash_fixture, :add, 2, ctx.tracer)

    :erpc.call(ctx.node, :code, :purge, [:beamdash_fixture])
    {:module, _} = :erpc.call(ctx.node, :code, :load_file, [:beamdash_fixture])
    assert_receive {:beamdash_trace, {:module_loaded, :beamdash_fixture}}, 5_000

    assert 7 = :erpc.call(ctx.node, :beamdash_fixture, :add, [3, 4])
    assert %{fun: :add, result: {:return, 7}} = next_completed_entry()
  end

  test "a flood of calls trips erlyberly's overload cut-off", ctx do
    :ok = Tracer.start_trace(:beamdash_fixture, :add, 2, ctx.tracer)
    assert_receive {:beamdash_trace, :traces_changed}

    :ok = :erpc.call(ctx.node, :beamdash_fixture, :spin, [200_000], 30_000)

    assert_receive {:beamdash_trace, {:overload, queue_len}}, 15_000
    assert queue_len > 1_000
    assert [] = Tracer.traces(ctx.tracer)
    # tracing is really off on the target
    assert {:traced, false} =
             :erpc.call(ctx.node, :erlang, :trace_info, [{:beamdash_fixture, :add, 2}, :traced])
  end

  test "loads of untraced modules are not reported", ctx do
    :ok = Tracer.start_trace(:beamdash_fixture, :add, 2, ctx.tracer)
    {:module, _} = :erpc.call(ctx.node, :code, :ensure_loaded, [:dets])
    refute_receive {:beamdash_trace, {:module_loaded, _}}, 300
  end

  test "a lost node clears the active traces", ctx do
    :ok = Tracer.start_trace(:beamdash_fixture, :add, 2, ctx.tracer)
    assert_receive {:beamdash_trace, :traces_changed}
    :peer.stop(ctx.peer)
    assert_receive {:beamdash_trace, :traces_changed}, 5_000
    assert [] = Tracer.traces(ctx.tracer)
  end

  test "a trace with a call limit stops itself after that many calls", ctx do
    assert :ok = Tracer.start_trace(:beamdash_fixture, :add, 2, [limit: 3], ctx.tracer)
    assert %{{:beamdash_fixture, :add, 2} => 3} = Tracer.limits(ctx.tracer)

    # more calls than the limit, in a burst: the ones over it may still
    # reach the collector while the trace is being switched off
    for i <- 1..6, do: :erpc.call(ctx.node, :beamdash_fixture, :add, [i, i])

    assert_receive {:beamdash_trace, {:remaining, {:beamdash_fixture, :add, 2}, 2}}, 2_000
    assert_receive {:beamdash_trace, {:remaining, {:beamdash_fixture, :add, 2}, 1}}, 2_000
    assert_receive {:beamdash_trace, {:limit_reached, {:beamdash_fixture, :add, 2}, 3}}, 2_000

    Process.sleep(300)
    assert [] = Tracer.traces(ctx.tracer)
    assert Tracer.limits(ctx.tracer) == %{}

    # exactly three calls recorded, each with its result
    calls = Tracer.entries(ctx.tracer) |> Enum.filter(&(&1.fun == :add)) |> Enum.reverse()
    assert Enum.map(calls, & &1.args) == [[1, 1], [2, 2], [3, 3]]
    assert Enum.map(calls, & &1.result) == [{:return, 2}, {:return, 4}, {:return, 6}]

    # and nothing more once it has stopped
    :erpc.call(ctx.node, :beamdash_fixture, :add, [9, 9])
    Process.sleep(300)
    assert length(Enum.filter(Tracer.entries(ctx.tracer), &(&1.fun == :add))) == 3
  end

  test "a trace without a limit runs until stopped", ctx do
    assert :ok = Tracer.start_trace(:beamdash_fixture, :add, 2, ctx.tracer)
    assert Tracer.limits(ctx.tracer) == %{}
    for i <- 1..5, do: :erpc.call(ctx.node, :beamdash_fixture, :add, [i, i])
    Process.sleep(500)
    assert [{:beamdash_fixture, :add, 2}] = Tracer.traces(ctx.tracer)
    refute_received {:beamdash_trace, {:limit_reached, _, _}}
  end

  describe "every function of a module (wildcard)" do
    test "traces exported and local calls, until stopped", ctx do
      assert :ok = Tracer.start_trace(:beamdash_fixture, :_, :_, ctx.tracer)
      assert [{:beamdash_fixture, :_, :_}] = Tracer.traces(ctx.tracer)

      # spin/1 calls itself and add/2: all three show up
      :ok = :erpc.call(ctx.node, :beamdash_fixture, :spin, [2])
      Process.sleep(400)

      funs =
        Tracer.entries(ctx.tracer)
        |> Enum.filter(&(&1.mod == :beamdash_fixture))
        |> Enum.map(&{&1.fun, &1.arity})
        |> Enum.frequencies()

      assert funs[{:spin, 1}] == 3
      assert funs[{:add, 2}] == 2

      assert :ok = Tracer.stop_trace(:beamdash_fixture, :_, :_, ctx.tracer)
      assert [] = Tracer.traces(ctx.tracer)
      before = length(Tracer.entries(ctx.tracer))
      :erpc.call(ctx.node, :beamdash_fixture, :add, [1, 1])
      Process.sleep(300)
      assert length(Tracer.entries(ctx.tracer)) == before
    end

    test "a call limit counts calls of any function", ctx do
      wild = {:beamdash_fixture, :_, :_}
      assert :ok = Tracer.start_trace(:beamdash_fixture, :_, :_, [limit: 4], ctx.tracer)
      # spin(3): spin x4 and add x3 = 7 calls, over the limit
      :ok = :erpc.call(ctx.node, :beamdash_fixture, :spin, [3])
      assert_receive {:beamdash_trace, {:limit_reached, ^wild, 4}}, 2_000
      Process.sleep(300)
      assert [] = Tracer.traces(ctx.tracer)
      assert length(Enum.filter(Tracer.entries(ctx.tracer), &(&1.mod == :beamdash_fixture))) == 4
    end

    # A finished whole-module trace leaves a 0 count behind (to drop calls
    # still arriving while it is switched off). It must not swallow the calls
    # of single-function traces started on that module afterwards, nor the
    # other way round.
    test "a whole-module trace that hit its limit does not hide later traces", ctx do
      wild = {:beamdash_fixture, :_, :_}
      add = {:beamdash_fixture, :add, 2}
      assert :ok = Tracer.start_trace(:beamdash_fixture, :_, :_, [limit: 2], ctx.tracer)
      :ok = :erpc.call(ctx.node, :beamdash_fixture, :spin, [3])
      assert_receive {:beamdash_trace, {:limit_reached, ^wild, 2}}, 2_000
      Process.sleep(300)
      :ok = Tracer.clear(ctx.tracer)
      flush()

      assert :ok = Tracer.start_trace(:beamdash_fixture, :add, 2, [limit: 5], ctx.tracer)
      assert 5 = :erpc.call(ctx.node, :beamdash_fixture, :add, [2, 3])
      assert %{mod: :beamdash_fixture, fun: :add, result: {:return, 5}} = next_completed_entry()
      assert Tracer.limits(ctx.tracer) == %{add => 4}

      # and back: a single-function trace that ran out, then the whole module
      :ok = :erpc.call(ctx.node, :beamdash_fixture, :spin, [4])
      assert_receive {:beamdash_trace, {:limit_reached, ^add, 5}}, 2_000
      Process.sleep(300)
      flush()
      assert :ok = Tracer.start_trace(:beamdash_fixture, :_, :_, [limit: 3], ctx.tracer)
      assert 7 = :erpc.call(ctx.node, :beamdash_fixture, :add, [3, 4])
      assert %{fun: :add, result: {:return, 7}} = next_completed_entry()
      assert Tracer.limits(ctx.tracer) == %{wild => 2}
    end

    test "does not mix with single-function traces of the same module", ctx do
      assert :ok = Tracer.start_trace(:beamdash_fixture, :add, 2, ctx.tracer)

      assert {:error, {:functions_traced, :beamdash_fixture}} =
               Tracer.start_trace(:beamdash_fixture, :_, :_, ctx.tracer)

      :ok = Tracer.stop_trace(:beamdash_fixture, :add, 2, ctx.tracer)
      assert :ok = Tracer.start_trace(:beamdash_fixture, :_, :_, ctx.tracer)

      assert {:error, {:module_traced, :beamdash_fixture}} =
               Tracer.start_trace(:beamdash_fixture, :add, 2, ctx.tracer)
    end

    test "is refused for the modules tracing runs in", ctx do
      for mod <- [:erlyberly, :dbg, :erlang] do
        refute Tracer.wildcard_allowed?(mod)

        assert {:error, {:wildcard_not_allowed, ^mod}} =
                 Tracer.start_trace(mod, :_, :_, ctx.tracer)
      end

      assert Tracer.wildcard_allowed?(:beamdash_fixture)
      assert Beamdash.Format.mfa({:beamdash_fixture, :_, :_}) == "beamdash_fixture:_/_"
      assert Beamdash.Format.mfa({String.Chars, :_, :_}, :elixir) == "String.Chars._/_"
    end
  end
end
