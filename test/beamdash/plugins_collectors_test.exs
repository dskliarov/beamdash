defmodule Beamdash.Plugins.CollectorsTest do
  use ExUnit.Case, async: false

  alias Beamdash.Plugins.Collectors

  @moduletag :capture_log

  # Stands in for Beamdash.Plugins (:active) and Beamdash.Target (:status).
  defmodule Fake do
    use GenServer
    def start_link(value), do: GenServer.start_link(__MODULE__, value)
    def set(server, value), do: GenServer.call(server, {:set, value})
    def init(value), do: {:ok, value}
    def handle_call({:set, value}, _from, _), do: {:reply, :ok, value}
    def handle_call(:active, _from, plugins), do: {:reply, plugins, plugins}
    def handle_call(:status, _from, nil), do: {:reply, %{status: :disconnected}, nil}
    def handle_call(:status, _from, node), do: {:reply, %{status: :connected, node: node}, node}
  end

  # The collectors under test: each reports its call to the test process
  # (registered as :collectors_test) and answers as told.
  defmodule Collect do
    def count(state) do
      send(:collectors_test, {:called, :count, state})
      {:ok, (state || 0) + 1}
    end

    def fail(state) do
      send(:collectors_test, {:called, :fail, state})
      {:error, "nope"}
    end

    def crash(state) do
      send(:collectors_test, {:called, :crash, state})
      raise "boom"
    end

    def slow(state) do
      send(:collectors_test, {:called, :slow, state})
      Process.sleep(:infinity)
    end
  end

  setup do
    Process.register(self(), :collectors_test)
    sup = start_supervised!(Task.Supervisor)
    {:ok, target} = Fake.start_link(:a@h)
    {:ok, plugins} = Fake.start_link([])

    server =
      start_supervised!(
        {Collectors, name: nil, plugins: plugins, target: target, task_sup: sup, tick: :manual}
      )

    %{server: server, plugins: plugins, target: target}
  end

  defp plugin(collectors) do
    collectors =
      for {name, interval, fun} <- collectors,
          do: %{name: name, interval: interval, call: {Collect, fun}}

    [%{app: :p, collectors: collectors}]
  end

  # Waits for the server to take in its tasks' replies.
  defp settle(server), do: :sys.get_state(server)

  test "calls a due collector with the state its previous call returned", ctx do
    Fake.set(ctx.plugins, plugin([{"count", 1_000, :count}]))

    :ok = Collectors.tick(ctx.server)
    assert_receive {:called, :count, nil}
    settle(ctx.server)
    assert Collectors.states(ctx.server) == %{{:p, "count"} => 1}

    # not due yet: the interval starts when the previous call ended
    :ok = Collectors.tick(ctx.server)
    refute_receive {:called, :count, _}, 100

    Process.sleep(1_000)
    :ok = Collectors.tick(ctx.server)
    assert_receive {:called, :count, 1}
  end

  test "an error or a crash keeps the previous state", ctx do
    Fake.set(ctx.plugins, plugin([{"fail", 1_000, :fail}, {"crash", 1_000, :crash}]))

    :ok = Collectors.tick(ctx.server)
    assert_receive {:called, :fail, nil}
    assert_receive {:called, :crash, nil}
    Process.sleep(50)
    settle(ctx.server)
    assert Collectors.states(ctx.server) == %{{:p, "fail"} => nil, {:p, "crash"} => nil}
  end

  test "a call is not started again while it runs, and is stopped after its interval", ctx do
    Fake.set(ctx.plugins, plugin([{"slow", 1_000, :slow}]))

    :ok = Collectors.tick(ctx.server)
    assert_receive {:called, :slow, nil}
    %{entries: %{{:p, "slow"} => %{task: %{pid: pid}}}} = settle(ctx.server)

    :ok = Collectors.tick(ctx.server)
    refute_receive {:called, :slow, _}, 100
    assert Process.alive?(pid)

    Process.sleep(1_000)
    :ok = Collectors.tick(ctx.server)
    refute Process.alive?(pid)
  end

  test "another node, no node or an inactive plugin drops the state", ctx do
    Fake.set(ctx.plugins, plugin([{"count", 1_000, :count}]))
    :ok = Collectors.tick(ctx.server)
    assert_receive {:called, :count, nil}
    settle(ctx.server)

    Fake.set(ctx.target, :b@h)
    :ok = Collectors.tick(ctx.server)
    assert_receive {:called, :count, nil}
    settle(ctx.server)

    Fake.set(ctx.target, nil)
    :ok = Collectors.tick(ctx.server)
    assert Collectors.states(ctx.server) == %{}
    refute_receive {:called, :count, _}, 100

    Fake.set(ctx.target, :b@h)
    Fake.set(ctx.plugins, [])
    :ok = Collectors.tick(ctx.server)
    assert Collectors.states(ctx.server) == %{}
  end
end
