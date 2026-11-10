defmodule Beamdash.AnomalyMonitorTest do
  use ExUnit.Case, async: true

  alias Beamdash.AnomalyMonitor

  @base_ms 1_800_000_000_000
  @step_s 2

  defp pid(i), do: :c.pid(0, 500 + i, 0)

  # a pool of peers, one of which is far above the others when `outlier?`
  defp procs(outlier?) do
    for i <- 10..29 do
      memory = if i == 10 and outlier?, do: 90_000_000, else: 50_000 + i * 100

      %{
        pid: pid(i),
        memory: memory,
        message_queue_len: 0,
        reductions: 0,
        kind: :gen_server,
        initial_call: {:pool, :init, 1},
        registered_name: nil,
        status: :waiting
      }
    end
  end

  setup do
    world =
      start_supervised!(
        {Agent,
         fn ->
           %{
             status: %{status: :connected, node: :app@host},
             procs: procs(false),
             clock: {@base_ms, 1_000_000}
           }
         end}
      )

    monitor = :"monitor_#{System.unique_integer([:positive])}"

    start_supervised!(
      {AnomalyMonitor,
       name: monitor,
       interval: :infinity,
       source: %{
         status: fn -> Agent.get(world, & &1.status) end,
         processes: fn -> {:ok, Agent.get(world, & &1.procs)} end,
         clock: fn -> Agent.get(world, & &1.clock) end
       }}
    )

    %{world: world, monitor: monitor}
  end

  defp set(world, changes), do: Agent.update(world, &Map.merge(&1, Map.new(changes)))

  defp tick(%{world: world, monitor: monitor}) do
    Agent.update(world, fn w ->
      {ms, us} = w.clock
      %{w | clock: {ms + @step_s * 1_000, us + @step_s * 1_000_000}}
    end)

    :ok = AnomalyMonitor.tick(monitor)
  end

  defp ticks(ctx, n), do: Enum.each(1..n, fn _ -> tick(ctx) end)

  test "the current check is collecting until enough samples are in", ctx do
    ticks(ctx, 3)

    assert %{readiness: {:collecting, 2, 8}, findings: []} = AnomalyMonitor.current(ctx.monitor)
  end

  test "a process far above its peers is one episode, saved to the history once it stops", ctx do
    set(ctx.world, procs: procs(true))
    ticks(ctx, 12)

    assert Enum.any?(
             AnomalyMonitor.current(ctx.monitor).findings,
             &(&1.pid == pid(10) and &1.kind == :peer_outlier)
           )

    set(ctx.world, procs: procs(false))
    tick(ctx)

    refute Enum.any?(AnomalyMonitor.current(ctx.monitor).findings, &(&1.pid == pid(10)))

    assert [episode] = AnomalyMonitor.history(ctx.monitor)

    assert %{
             pid: pid10,
             measure: :memory,
             kind: :peer_outlier,
             node: "app@host",
             samples: 4,
             duration_ms: 6_000
           } = episode

    assert pid10 == pid(10)
  end

  test "clearing the history takes the episodes out", ctx do
    set(ctx.world, procs: procs(true))
    ticks(ctx, 9)
    set(ctx.world, procs: procs(false))
    tick(ctx)

    assert [_] = AnomalyMonitor.history(ctx.monitor, clear: true)
    assert [] == AnomalyMonitor.history(ctx.monitor)
  end

  test "a disconnect closes the open episodes under the node they were seen on", ctx do
    set(ctx.world, procs: procs(true))
    ticks(ctx, 9)
    set(ctx.world, status: %{status: :disconnected, node: nil})
    tick(ctx)

    assert [%{node: "app@host", pid: pid10}] = AnomalyMonitor.history(ctx.monitor)
    assert pid10 == pid(10)
    assert %{readiness: {:collecting, 0, 8}, findings: []} = AnomalyMonitor.current(ctx.monitor)
  end
end
