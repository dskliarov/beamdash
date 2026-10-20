defmodule Exberly.ProcessStatsTest do
  use ExUnit.Case, async: true

  alias Exberly.ProcessStats

  test "table rates are reductions per second since the previous sample" do
    a = :c.pid(0, 1, 0)
    b = :c.pid(0, 2, 0)
    {rates, sample} = ProcessStats.table_rates([%{pid: a, reductions: 100}], %{}, 0)
    assert rates == %{a => nil}

    procs = [%{pid: a, reductions: 2_100}, %{pid: b, reductions: 50}]
    {rates, _} = ProcessStats.table_rates(procs, sample, 2_000_000)
    assert rates == %{a => 1_000, b => nil}
  end

  test "detail history computes a rate per point and keeps the last 60" do
    sample = fn at_s, reds ->
      %{
        sampled_at_us: at_s * 1_000_000,
        reductions: reds,
        memory: %{total: 1000},
        mailbox: %{length: 0}
      }
    end

    history = ProcessStats.push([], sample.(0, 0))
    assert [%{reds_per_sec: nil}] = history
    history = ProcessStats.push(history, sample.(2, 500))
    assert [_, %{reds_per_sec: 250, memory: 1000}] = history

    long = Enum.reduce(1..100, [], fn i, h -> ProcessStats.push(h, sample.(i, i * 10)) end)
    assert length(long) == 60
    assert List.last(long).reductions == 1000
  end
end
