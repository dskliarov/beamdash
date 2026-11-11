defmodule Beamdash.SuspectsTest do
  use ExUnit.Case, async: true

  alias Beamdash.Insights.Suspects

  @spike "#PID<0.99.0>"

  defp row(at, pid, memory, queue \\ 0, rate \\ 0) do
    %{
      at: at,
      node: "app@host",
      pid: pid,
      reason: "memory",
      data: %{
        "process" => %{"name" => "worker", "memory" => memory, "message_queue_len" => queue},
        "rate" => rate
      }
    }
  end

  # 30 snapshots of 10 steady processes, plus a spike in 5 of them
  defp history do
    for at <- 1..30, i <- 1..10 do
      if i == 1 and rem(at, 6) == 0,
        do: row(at, @spike, 100_000_000, 40),
        else: row(at, "#PID<0.#{i}.0>", 1_000 + i * 10)
    end
  end

  test "a process that spikes across snapshots is the top suspect" do
    result = Suspects.analyze(history())

    assert [top | _] = result.suspects
    assert top.pid == @spike
    assert top.snapshots == 5
    assert top.feature == :memory
    assert top.name == "worker"
  end

  test "steady processes are not flagged" do
    result = Suspects.analyze(history())

    flagged_pids = result.flagged |> Map.keys() |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    assert flagged_pids == [@spike]
    assert map_size(result.flagged) == 5
  end

  test "too few rows give no suspects" do
    rows = for at <- 1..5, do: row(at, @spike, 100_000_000)

    assert %{flagged: flagged, suspects: []} = Suspects.analyze(rows)
    assert flagged == %{}
  end
end
