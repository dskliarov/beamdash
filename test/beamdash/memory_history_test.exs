defmodule Beamdash.MemoryHistoryTest do
  use ExUnit.Case, async: true

  alias Beamdash.MemoryHistory

  defp row(at, total, opts \\ []) do
    %{
      at: at,
      node: "app@host",
      data: %{
        "memory" => %{"total" => total, "processes" => 0},
        "atom_count" => Keyword.get(opts, :atoms, 10),
        "ets_count" => Keyword.get(opts, :ets, 2),
        "tables" => Keyword.get(opts, :tables, [])
      }
    }
  end

  defp table(name, memory),
    do: %{"name" => name, "memory" => memory, "type" => "set", "size" => 1, "owner" => "<0.1.0>"}

  test "the first sample has nothing to compare with" do
    assert [%{memory: 100, memory_delta: nil, atoms_delta: nil, ets_delta: nil, growing: []}] =
             MemoryHistory.changes([row(1, 100)])
  end

  test "each sample carries its change from the sample before" do
    assert [_, second] =
             MemoryHistory.changes([
               row(1, 100, atoms: 10, ets: 2),
               row(2, 150, atoms: 12, ets: 1)
             ])

    assert %{
             at: 2,
             memory: 150,
             memory_delta: 50,
             atoms: 12,
             atoms_delta: 2,
             ets: 1,
             ets_delta: -1
           } = second
  end

  test "growing lists the tables that rose, largest rise first, and at most three" do
    before = [table("a", 100), table("b", 500), table("c", 50), table("d", 10), table("e", 1)]
    now = [table("a", 400), table("b", 300), table("c", 90), table("d", 60), table("e", 9)]

    [_, second] = MemoryHistory.changes([row(1, 0, tables: before), row(2, 0, tables: now)])

    assert second.growing == [{"a", 300}, {"d", 50}, {"c", 40}]
  end

  test "tables new in a sample, or without a name, are not counted as growth" do
    before = [table("a", 100)]
    now = [table("a", 100), table("new", 999), %{"name" => nil, "memory" => 500}]

    [_, second] = MemoryHistory.changes([row(1, 0, tables: before), row(2, 0, tables: now)])

    assert second.growing == []
  end

  test "summary gives the first and last totals and the peak" do
    changes = MemoryHistory.changes([row(1, 100), row(2, 300), row(3, 200)])

    assert MemoryHistory.summary(changes) == %{samples: 3, from: 100, to: 200, peak: 300}
    assert MemoryHistory.summary([]) == nil
  end
end
