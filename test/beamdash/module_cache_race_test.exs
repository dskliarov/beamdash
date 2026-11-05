defmodule Beamdash.ModuleCacheRaceTest do
  use ExUnit.Case, async: false

  alias Beamdash.{ModuleCache, Target}

  defmodule FakeTracer do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call(:module_functions, from, test_pid) do
      send(test_pid, {:fetch, from})
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
    assert_receive {:fetch, _from}

    waiter = Task.async(fn -> ModuleCache.modules(ctx.cache) end)
    await_waiting(ctx.cache)

    send(ctx.cache, {:beamdash_target, {:disconnected, :n1@host}})

    assert {:error, :not_connected} = Task.await(waiter)
    assert %{task: nil, waiting: []} = :sys.get_state(ctx.cache)
  end

  test "a reconnect during a fetch fetches again and ignores the old node's answer", ctx do
    send(ctx.cache, {:beamdash_target, {:connected, :old@host}})
    assert_receive {:fetch, old}

    waiter = Task.async(fn -> ModuleCache.modules(ctx.cache) end)
    await_waiting(ctx.cache)

    send(ctx.cache, {:beamdash_target, {:connected, :new@host}})
    assert_receive {:fetch, new}

    GenServer.reply(old, {:ok, [{:stale, [], []}]})
    GenServer.reply(new, {:ok, [{:fresh, [], []}]})

    assert {:ok, [{:fresh, [], []}]} = Task.await(waiter)
    assert {:ok, [{:fresh, [], []}]} = ModuleCache.modules(ctx.cache)
  end

  defp await_waiting(cache, tries \\ 200) do
    cond do
      :sys.get_state(cache).waiting != [] -> :ok
      tries == 0 -> flunk("no caller started waiting for the module list")
      true -> Process.sleep(5) && await_waiting(cache, tries - 1)
    end
  end
end
