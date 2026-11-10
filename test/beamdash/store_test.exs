defmodule Beamdash.StoreTest do
  use ExUnit.Case, async: false

  alias Beamdash.Store

  @now 1_800_000_000_000
  @day 86_400_000

  setup do
    dir = Path.join(System.tmp_dir!(), "beamdash_store_#{System.unique_integer([:positive])}")
    path = Path.join(dir, "events.sqlite3")
    name = :"store_#{System.unique_integer([:positive])}"

    start = fn ->
      start_supervised!({Store, name: name, path: path, purge_interval: :infinity})
    end

    start.()

    on_exit(fn ->
      Application.delete_env(:beamdash, :retention)
      File.rm_rf(dir)
    end)

    %{name: name, start: start, path: path}
  end

  defp snapshot(at, pid), do: %{at: at, node: "app@host", pid: pid, reason: "memory", data: %{}}

  test "queries rows newest first, within a time range and filtered by pid", ctx do
    :ok =
      Store.record(
        :snapshots,
        [
          snapshot(@now - 2_000, "<0.1.0>"),
          snapshot(@now - 1_000, "<0.2.0>"),
          snapshot(@now, "<0.1.0>"),
          snapshot(@now + 5_000, "<0.1.0>")
        ],
        ctx.name
      )

    rows = Store.query(:snapshots, [from: @now - 5_000, to: @now, pid: "<0.1.0>"], ctx.name)

    assert Enum.map(rows, & &1.at) == [@now, @now - 2_000]
    assert Enum.all?(rows, &(&1.pid == "<0.1.0>" and &1.reason == "memory"))
  end

  test "times lists each stored time once, newest first, with its row count", ctx do
    :ok =
      Store.record(
        :snapshots,
        [
          snapshot(@now - 1_000, "<0.1.0>"),
          snapshot(@now - 1_000, "<0.2.0>"),
          snapshot(@now, "<0.1.0>")
        ],
        ctx.name
      )

    assert [%{at: @now, count: 1}, %{at: at, count: 2}] = Store.times(:snapshots, [], ctx.name)
    assert at == @now - 1_000
    assert [%{at: at}] = Store.times(:snapshots, [pid: "<0.2.0>"], ctx.name)
    assert at == @now - 1_000
  end

  test "keeps the details as JSON and returns them decoded", ctx do
    :ok =
      Store.record(
        :anomalies,
        [
          %{
            at: @now,
            node: "app@host",
            pid: "<0.9.0>",
            measure: "memory",
            data: %{text: "heap rising", score: 3.5}
          }
        ],
        ctx.name
      )

    assert [%{measure: "memory", data: %{"text" => "heap rising", "score" => 3.5}}] =
             Store.query(:anomalies, [], ctx.name)
  end

  test "purge deletes rows older than the kind's max age and keeps newer ones", ctx do
    :ok =
      Store.record(
        :snapshots,
        [snapshot(@now - 8 * @day, "<0.1.0>"), snapshot(@now - 6 * @day, "<0.2.0>")],
        ctx.name
      )

    assert %{snapshots: 1} = Store.purge(@now, ctx.name)
    assert [%{pid: "<0.2.0>"}] = Store.query(:snapshots, [], ctx.name)
  end

  test "each kind follows its own retention, so purging one leaves the others alone", ctx do
    Application.put_env(:beamdash, :retention, %{logs: %{max_age_days: 1}})

    :ok = Store.record(:snapshots, [snapshot(@now - 8 * @day, "<0.1.0>")], ctx.name)

    :ok =
      Store.record(
        :logs,
        [
          %{at: @now - 2 * @day, node: "app@host", level: "error", data: %{}},
          %{at: @now - 3_600_000, node: "app@host", level: "error", data: %{}}
        ],
        ctx.name
      )

    :ok =
      Store.record(
        :ai_analyses,
        [%{at: @now - 2 * @day, node: "app@host", subject: "anomaly:4", data: %{"text" => "x"}}],
        ctx.name
      )

    assert %{snapshots: 1, logs: 1, ai_analyses: 0} = Store.purge(@now, ctx.name)
    assert [%{at: at}] = Store.query(:logs, [], ctx.name)
    assert at == @now - 3_600_000
    assert [%{subject: "anomaly:4"}] = Store.query(:ai_analyses, [], ctx.name)
  end

  test "purge keeps only max_rows of a kind, dropping the oldest", ctx do
    Application.put_env(:beamdash, :retention, %{snapshots: %{max_rows: 2}})

    :ok =
      Store.record(
        :snapshots,
        for(i <- 0..4, do: snapshot(@now - i * 1_000, "<0.#{i}.0>")),
        ctx.name
      )

    assert %{snapshots: 3} = Store.purge(@now, ctx.name)
    assert [@now, @now - 1_000] == Enum.map(Store.query(:snapshots, [], ctx.name), & &1.at)
  end

  test "purge deletes in batches when more rows than one batch are expired", ctx do
    rows = for i <- 1..5_003, do: snapshot(@now - 8 * @day - i, "<0.1.0>")
    :ok = Store.record(:snapshots, rows, ctx.name)

    assert %{snapshots: 5_003} = Store.purge(@now, ctx.name)
    assert [] == Store.query(:snapshots, [limit: 10], ctx.name)
  end

  test "stored rows survive a restart of the store", ctx do
    :ok = Store.record(:snapshots, [snapshot(@now, "<0.1.0>")], ctx.name)

    stop_supervised!(Store)
    ctx.start.()

    assert [%{pid: "<0.1.0>"}] = Store.query(:snapshots, [], ctx.name)
  end

  test "a store at schema version 1 gets the memory table on start, keeping its rows", ctx do
    :ok = Store.record(:snapshots, [snapshot(@now, "<0.1.0>")], ctx.name)
    stop_supervised!(Store)

    {:ok, db} = Exqlite.Sqlite3.open(ctx.path)
    :ok = Exqlite.Sqlite3.execute(db, "DROP TABLE memory")
    :ok = Exqlite.Sqlite3.execute(db, "PRAGMA user_version = 1")
    :ok = Exqlite.Sqlite3.close(db)

    ctx.start.()

    :ok = Store.record(:memory, [%{at: @now, node: "app@host", data: %{"total" => 1}}], ctx.name)
    assert [%{data: %{"total" => 1}}] = Store.query(:memory, [], ctx.name)
    assert [%{pid: "<0.1.0>"}] = Store.query(:snapshots, [], ctx.name)
  end

  test "queries can be limited to one node", ctx do
    :ok =
      Store.record(
        :anomalies,
        [
          %{at: @now, node: "a@host", pid: "<0.1.0>", measure: "memory", data: %{}},
          %{at: @now, node: "b@host", pid: "<0.1.0>", measure: "memory", data: %{}}
        ],
        ctx.name
      )

    assert [%{node: "a@host"}] = Store.query(:anomalies, [node: "a@host"], ctx.name)
  end

  test "policy merges overrides onto the defaults" do
    Application.put_env(:beamdash, :retention, %{logs: %{max_age_days: 1}})

    assert Store.policy().logs == %{max_age_days: 1, max_rows: 300_000}
    assert Store.policy().snapshots == %{max_age_days: 7, max_rows: 500_000}
  end
end
