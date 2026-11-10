defmodule Beamdash.Store do
  @moduledoc """
  The event store: snapshots of processes that need attention, anomalies,
  node memory samples, log lines and AI analyses, kept in one SQLite file.

  Each kind has its own retention (`policy/0`). Rows older than `max_age_days`
  are purged, and so are the oldest rows beyond `max_rows`. Purging runs
  periodically and deletes in batches, so a writer never waits long. Kinds are
  independent: purging snapshots never touches analyses.

  `data` is stored as JSON, so it must hold only JSON-encodable values.
  """
  use GenServer

  alias Exqlite.Sqlite3

  @kinds %{
    snapshots: [:pid, :reason],
    anomalies: [:pid, :measure],
    logs: [:level],
    memory: [],
    ai_analyses: [:subject]
  }

  @defaults %{
    snapshots: %{max_age_days: 7, max_rows: 500_000},
    anomalies: %{max_age_days: 30, max_rows: 100_000},
    logs: %{max_age_days: 3, max_rows: 300_000},
    memory: %{max_age_days: 7, max_rows: 25_000},
    ai_analyses: %{max_age_days: 90, max_rows: 10_000}
  }

  @batch 5_000
  @day_ms 86_400_000
  @far_future 1_000_000_000_000_000
  @default_purge_ms 3_600_000

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The file the events are stored in, or `nil` when storing is off."
  def path do
    case Application.get_env(:beamdash, :store_file) do
      false -> nil
      nil -> Path.join(:filename.basedir(:user_data, "beamdash"), "events.sqlite3")
      path -> path
    end
  end

  @doc "Retention per kind: `%{max_age_days, max_rows}`, the defaults overridden by `config :beamdash, :retention`."
  def policy do
    overrides = Application.get_env(:beamdash, :retention, %{})

    Map.merge(@defaults, Map.new(overrides), fn _kind, default, override ->
      Map.merge(default, Map.new(override))
    end)
  end

  @doc """
  Stores `rows` of `kind`. Each row is a map with `:at` (unix ms), `:node`,
  `:data`, and the kind's key fields (`snapshots`: `:pid`, `:reason`;
  `anomalies`: `:pid`, `:measure`; `logs`: `:level`; `ai_analyses`: `:subject`).
  """
  def record(kind, rows, server \\ __MODULE__), do: GenServer.call(server, {:record, kind, rows})

  @doc """
  Stores `row` of `kind` unless a row of `kind` at or after `from` (unix ms)
  already has `same` (`[key: value]`, matched against its `data`). Returns
  `:stored` or `:existing`. The check and the write happen in one step.
  """
  def record_unless(kind, row, same, from, server \\ __MODULE__),
    do: GenServer.call(server, {:record_unless, kind, row, same, from})

  @doc """
  Rows of `kind` with `at` in `from..to` (unix ms), newest first. Options:
  `:from`, `:to`, `:limit` (default 100), and any key field to filter on.
  """
  def query(kind, opts \\ [], server \\ __MODULE__),
    do: GenServer.call(server, {:query, kind, opts})

  @doc """
  The distinct `at` values of `kind` with their row counts, newest first, with
  the same options as `query/3`. A snapshot is every row of one `at`.
  """
  def times(kind, opts \\ [], server \\ __MODULE__),
    do: GenServer.call(server, {:times, kind, opts})

  @doc "Applies the policy now, as of `now` (unix ms). Returns the deleted row count per kind."
  def purge(now \\ System.system_time(:millisecond), server \\ __MODULE__),
    do: GenServer.call(server, {:purge, now}, :infinity)

  @impl true
  def init(opts) do
    path = Keyword.get_lazy(opts, :path, &path/0)
    interval = Keyword.get(opts, :purge_interval, @default_purge_ms)

    File.mkdir_p!(Path.dirname(path))
    {:ok, db} = Sqlite3.open(path)
    migrate(db)
    schedule(interval)

    {:ok, %{db: db, interval: interval}}
  end

  @impl true
  def handle_call({:record, kind, rows}, _from, state) do
    transaction(state.db, fn -> Enum.each(rows, &insert(state.db, kind, &1)) end)
    {:reply, :ok, state}
  end

  def handle_call({:record_unless, kind, row, same, from}, _from, state) do
    reply =
      transaction(state.db, fn ->
        if duplicate?(state.db, kind, same, from) do
          :existing
        else
          insert(state.db, kind, row)
          :stored
        end
      end)

    {:reply, reply, state}
  end

  def handle_call({:query, kind, opts}, _from, state) do
    keys = Map.fetch!(@kinds, kind)
    key_cols = Enum.map(keys, &Atom.to_string/1)
    {where, args} = conditions(keys, opts)

    sql =
      "SELECT id, at, node, #{Enum.join(key_cols ++ ["data"], ", ")} FROM #{kind} " <>
        "WHERE #{where} ORDER BY at DESC, id DESC LIMIT ?"

    rows =
      for row <- run(state.db, sql, args ++ [Keyword.get(opts, :limit, 100)]),
          do: decode_row(keys, row)

    {:reply, rows, state}
  end

  def handle_call({:times, kind, opts}, _from, state) do
    {where, args} = conditions(Map.fetch!(@kinds, kind), opts)
    sql = "SELECT at, count(*) FROM #{kind} WHERE #{where} GROUP BY at ORDER BY at DESC LIMIT ?"

    rows =
      for [at, count] <- run(state.db, sql, args ++ [Keyword.get(opts, :limit, 100)]),
          do: %{at: at, count: count}

    {:reply, rows, state}
  end

  def handle_call({:purge, now}, _from, state) do
    {:reply, purge_all(state.db, policy(), now), state}
  end

  @impl true
  def handle_info(:purge, state) do
    purge_all(state.db, policy(), System.system_time(:millisecond))
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{db: db}), do: Sqlite3.close(db)

  defp schedule(:infinity), do: :ok
  defp schedule(ms), do: Process.send_after(self(), :purge, ms)

  defp migrate(db) do
    run(db, "PRAGMA journal_mode = WAL")
    run(db, "PRAGMA synchronous = NORMAL")
    [[version]] = run(db, "PRAGMA user_version")

    # must be set before the first table exists, so freed pages can be returned
    if version < 1, do: run(db, "PRAGMA auto_vacuum = INCREMENTAL")

    # version 2 added the memory kind; IF NOT EXISTS creates only the missing tables
    if version < 2 do
      for {kind, keys} <- @kinds do
        key_cols = Enum.map(keys, &"#{&1} TEXT")

        run(
          db,
          "CREATE TABLE IF NOT EXISTS #{kind} (id INTEGER PRIMARY KEY, at INTEGER NOT NULL, " <>
            "node TEXT NOT NULL, #{Enum.join(key_cols ++ ["data TEXT NOT NULL"], ", ")})"
        )

        run(db, "CREATE INDEX IF NOT EXISTS #{kind}_at ON #{kind} (at)")

        for key <- keys,
            do: run(db, "CREATE INDEX IF NOT EXISTS #{kind}_#{key} ON #{kind} (#{key}, at)")
      end

      run(db, "PRAGMA user_version = 2")
    end
  end

  defp purge_all(db, policy, now) do
    deleted =
      for {kind, %{max_age_days: days, max_rows: max_rows}} <- policy, into: %{} do
        by_age = delete_older_than(db, kind, now - days * @day_ms)
        by_count = delete_over(db, kind, max_rows)
        {kind, by_age + by_count}
      end

    run(db, "PRAGMA incremental_vacuum")
    deleted
  end

  defp delete_older_than(db, kind, cutoff) do
    sql = "DELETE FROM #{kind} WHERE id IN (SELECT id FROM #{kind} WHERE at < ? LIMIT ?)"
    drain(db, sql, [cutoff], @batch, 0)
  end

  defp delete_over(db, kind, max_rows) do
    [[count]] = run(db, "SELECT count(*) FROM #{kind}")
    delete_excess(db, kind, count - max_rows, 0)
  end

  defp delete_excess(_db, _kind, excess, deleted) when excess <= 0, do: deleted

  defp delete_excess(db, kind, excess, deleted) do
    limit = min(excess, @batch)

    sql =
      "DELETE FROM #{kind} WHERE id IN " <>
        "(SELECT id FROM #{kind} ORDER BY at ASC, id ASC LIMIT ?)"

    n = delete_batch(db, sql, [limit])

    if n < limit,
      do: deleted + n,
      else: delete_excess(db, kind, excess - n, deleted + n)
  end

  defp drain(db, sql, args, limit, deleted) do
    n = delete_batch(db, sql, args ++ [limit])

    if n < limit,
      do: deleted + n,
      else: drain(db, sql, args, limit, deleted + n)
  end

  defp delete_batch(db, sql, args) do
    run(db, sql, args)
    [[n]] = run(db, "SELECT changes()")
    n
  end

  defp transaction(db, fun) do
    run(db, "BEGIN IMMEDIATE")

    try do
      result = fun.()
      run(db, "COMMIT")
      result
    rescue
      e ->
        run(db, "ROLLBACK")
        reraise e, __STACKTRACE__
    end
  end

  defp run(db, sql, args \\ []) do
    {:ok, stmt} = Sqlite3.prepare(db, sql)
    :ok = Sqlite3.bind(stmt, args)
    rows = collect(db, stmt, [])
    :ok = Sqlite3.release(db, stmt)
    rows
  end

  defp collect(db, stmt, acc) do
    case Sqlite3.step(db, stmt) do
      {:row, row} -> collect(db, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end

  defp insert(db, kind, row) do
    keys = Map.fetch!(@kinds, kind)
    cols = ["at", "node"] ++ Enum.map(keys, &Atom.to_string/1) ++ ["data"]
    sql = "INSERT INTO #{kind} (#{Enum.join(cols, ", ")}) VALUES (#{marks(length(cols))})"
    key_values = Enum.map(keys, &key_value(Map.get(row, &1)))
    data = row |> Map.get(:data, %{}) |> jsonable() |> Jason.encode!()
    run(db, sql, [Map.fetch!(row, :at), Map.fetch!(row, :node) | key_values] ++ [data])
  end

  defp duplicate?(db, kind, same, from) do
    conds = Enum.map_join(same, " AND ", fn _ -> "json_extract(data, ?) = ?" end)
    args = Enum.flat_map(same, fn {key, value} -> ["$.#{key}", value] end)
    run(db, "SELECT 1 FROM #{kind} WHERE at >= ? AND #{conds} LIMIT 1", [from | args]) != []
  end

  defp conditions(keys, opts) do
    filters =
      for key <- keys ++ [:node], Keyword.has_key?(opts, key) do
        {"#{key} = ?", key_value(Keyword.fetch!(opts, key))}
      end

    where = Enum.join(["at >= ?", "at <= ?" | Enum.map(filters, &elem(&1, 0))], " AND ")
    args = [Keyword.get(opts, :from, 0), Keyword.get(opts, :to, @far_future)]
    {where, args ++ Enum.map(filters, &elem(&1, 1))}
  end

  defp decode_row(keys, [id, at, node | rest]) do
    {key_values, [data]} = Enum.split(rest, length(keys))

    keys
    |> Enum.zip(key_values)
    |> Map.new()
    |> Map.merge(%{id: id, at: at, node: node, data: Jason.decode!(data)})
  end

  @doc "Converts `value` to terms Jason can encode: pids, tuples and other terms become their `inspect/1` text."
  def jsonable(value) when is_boolean(value) or is_number(value), do: value
  def jsonable(nil), do: nil
  def jsonable(value) when is_atom(value), do: Atom.to_string(value)

  def jsonable(value) when is_binary(value),
    do: if(String.valid?(value), do: value, else: inspect(value))

  def jsonable(%_{} = struct), do: struct |> Map.from_struct() |> jsonable()

  def jsonable(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {json_key(k), jsonable(v)} end)

  def jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  def jsonable(other), do: inspect(other)

  defp json_key(key) when is_binary(key), do: key
  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: inspect(key)

  defp key_value(nil), do: nil
  defp key_value(pid) when is_pid(pid), do: inspect(pid)
  defp key_value(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp key_value(value), do: value

  defp marks(count), do: Enum.map_join(1..count, ", ", fn _ -> "?" end)
end
