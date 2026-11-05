defmodule Beamdash.ModuleCacheRaceTest do
  use ExUnit.Case, async: false

  alias Beamdash.{ModuleCache, Settings, Target}

  @timeout_reply {:error, {:error, {:erpc, :timeout}}}

  defmodule FakeTracer do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call({:module_functions, timeout}, from, test_pid) do
      send(test_pid, {:fetch, timeout, from})
      {:noreply, test_pid}
    end
  end

  setup do
    id = System.unique_integer([:positive])
    target = start_supervised!({Target, name: :"race_target_#{id}"}, id: :target)
    tracer = start_supervised!({FakeTracer, self()}, id: :tracer)

    cache =
      start_supervised!(
        {ModuleCache, name: :"race_cache_#{id}", target: target, tracer: tracer},
        id: :cache
      )

    %{cache: cache}
  end

  test "a disconnect answers the callers waiting for the list and drops the fetch", ctx do
    send(ctx.cache, {:beamdash_target, {:connected, :n1@host}})
    assert_receive {:fetch, 30_000, _from}

    waiter = Task.async(fn -> ModuleCache.modules(ctx.cache) end)
    await_waiting(ctx.cache)

    send(ctx.cache, {:beamdash_target, {:disconnected, :n1@host}})

    assert {:error, :not_connected} = Task.await(waiter)
    assert %{task: nil, waiting: []} = :sys.get_state(ctx.cache)
  end

  test "a reconnect during a fetch fetches again and ignores the old node's answer", ctx do
    send(ctx.cache, {:beamdash_target, {:connected, :old@host}})
    assert_receive {:fetch, 30_000, old}

    waiter = Task.async(fn -> ModuleCache.modules(ctx.cache) end)
    await_waiting(ctx.cache)

    send(ctx.cache, {:beamdash_target, {:connected, :new@host}})
    assert_receive {:fetch, 30_000, new}

    GenServer.reply(old, {:ok, [{:stale, [], []}]})
    GenServer.reply(new, {:ok, [{:fresh, [], []}]})

    assert {:ok, [{:fresh, [], []}]} = Task.await(waiter)
    assert {:ok, [{:fresh, [], []}]} = ModuleCache.modules(ctx.cache)
  end

  test "timeouts retry at 33 s and 36 s, then wait 60 s before starting over at 30 s", ctx do
    send(ctx.cache, {:beamdash_target, {:connected, :n1@host}})
    assert_receive {:fetch, 30_000, first}

    waiter = Task.async(fn -> ModuleCache.modules(ctx.cache) end)
    await_waiting(ctx.cache)
    GenServer.reply(first, @timeout_reply)

    assert_receive {:fetch, 33_000, second}
    GenServer.reply(second, @timeout_reply)

    assert_receive {:fetch, 36_000, third}
    GenServer.reply(third, @timeout_reply)

    assert @timeout_reply = Task.await(waiter)
    refute_receive {:fetch, _, _}, 50
    assert %{task: nil, retry_timer: timer} = :sys.get_state(ctx.cache)
    assert is_reference(timer)

    send(ctx.cache, :retry)
    assert_receive {:fetch, 30_000, _}
  end

  test "the retry steps and the give-up wait follow the trace timeout setting", ctx do
    on_exit(fn -> Settings.put_trace_timeout(30_000) end)
    :ok = Settings.put_trace_timeout(60_000)

    send(ctx.cache, {:beamdash_target, {:connected, :n1@host}})
    assert_receive {:fetch, 60_000, first}

    waiter = Task.async(fn -> ModuleCache.modules(ctx.cache) end)
    await_waiting(ctx.cache)
    GenServer.reply(first, @timeout_reply)
    assert_receive {:fetch, 66_000, second}
    GenServer.reply(second, @timeout_reply)
    assert_receive {:fetch, 72_000, third}
    GenServer.reply(third, @timeout_reply)
    assert @timeout_reply = Task.await(waiter)

    assert %{retry_timer: timer} = :sys.get_state(ctx.cache)
    assert is_reference(timer)
    assert Process.read_timer(timer) > 60_000
  end

  test "a failure other than a timeout is answered at once, not retried", ctx do
    send(ctx.cache, {:beamdash_target, {:connected, :n1@host}})
    assert_receive {:fetch, 30_000, from}

    waiter = Task.async(fn -> ModuleCache.modules(ctx.cache) end)
    await_waiting(ctx.cache)
    GenServer.reply(from, {:error, :not_connected})

    assert {:error, :not_connected} = Task.await(waiter)
    refute_receive {:fetch, _, _}, 50
    assert %{retry_timer: nil, attempt: 0} = :sys.get_state(ctx.cache)
  end

  defp await_waiting(cache, tries \\ 200) do
    cond do
      :sys.get_state(cache).waiting != [] -> :ok
      tries == 0 -> flunk("no caller started waiting for the module list")
      true -> Process.sleep(5) && await_waiting(cache, tries - 1)
    end
  end
end
