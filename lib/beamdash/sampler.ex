defmodule Beamdash.Sampler do
  @moduledoc """
  Periodic snapshots of what needs attention on the connected node, kept in
  `Beamdash.Store`:

    * `snapshots`: the top 10 processes by reductions rate (reason `:load`),
      the top 10 by memory (`:memory`), and the top 10 whose memory rose at
      each of the last 5 samples (`:heap_rising`). Each row keeps the process
      fields and `Beamdash.Target.process_details/2`.
    * `anomalies`: the episodes `Beamdash.AnomalyMonitor` closed since the
      previous sample. They are taken from the monitor, which then forgets them,
      and stored only while snapshot collection is on.
    * `memory`: one row per sample with the node's `erlang:memory/0` breakdown,
      the atom and ETS counts, and the largest ETS tables (at most 10).
    * `logs`: the log lines added since the previous sample, oldest first.

  Nothing is sampled while disconnected. With snapshots switched off in
  Settings, `snapshots` are not taken but logs still are. A connection to
  another node starts fresh, so rates and histories never mix two nodes.
  """

  use GenServer

  alias Beamdash.{AnomalyMonitor, Logs, ProcessStats, Settings, Store, Target}

  @interval 30_000
  @top 10
  @rising 5
  @top_tables 10
  @process_fields [
    :name,
    :initial_call,
    :current_function,
    :memory,
    :message_queue_len,
    :reductions,
    :status
  ]

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Takes a sample now."
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick, :infinity)

  @doc "The sampling state for `node`, before any sample."
  def new(node), do: fresh(node)

  @doc """
  The snapshot rows of one sample of `procs` taken at `now_ms` (unix ms) and
  `now_us` (monotonic microseconds). `details_fun.(pid)` returns a process's
  details or `nil`. Returns the next state and the rows.
  """
  def observe(state, procs, now_ms, now_us, details_fun) do
    elapsed = if state.prev_at, do: now_us - state.prev_at, else: 0
    {rates, sample} = ProcessStats.table_rates(procs, state.prev_sample, elapsed)

    streaks = streaks(procs, state.streaks)

    by_pid = Map.new(procs, &{&1.pid, &1})
    pairs = attention(procs, rates, streaks)
    details = Map.new(Enum.uniq(Enum.map(pairs, &elem(&1, 0))), &{&1, details_fun.(&1)})

    rows =
      for {pid, reason} <- pairs do
        %{
          at: now_ms,
          node: state.node,
          pid: pid,
          reason: reason,
          data: %{
            process: Map.take(by_pid[pid], @process_fields),
            rate: rate(rates, pid),
            details: details[pid]
          }
        }
      end

    state = %{state | prev_sample: sample, prev_at: now_us, streaks: streaks}
    {state, rows}
  end

  @impl true
  def init(opts) do
    state =
      Map.merge(fresh(nil), %{
        interval: Keyword.get(opts, :interval, @interval),
        store: Keyword.get(opts, :store, Store),
        monitor: Keyword.get(opts, :monitor, AnomalyMonitor),
        source: Map.merge(default_source(), Map.new(Keyword.get(opts, :source, %{})))
      })

    schedule(state.interval)
    {:ok, state}
  end

  @impl true
  def handle_call(:tick, _from, state), do: {:reply, :ok, run(state)}

  @impl true
  def handle_info(:tick, state) do
    state = run(state)
    schedule(state.interval)
    {:noreply, state}
  end

  defp default_source do
    %{
      status: &Target.status/0,
      processes: &Target.processes/0,
      details: &Target.process_details/2,
      memory: &read_memory/1,
      logs: &Logs.entries/0
    }
  end

  # The Target.rpc default timeout (Settings.rpc_timeout), not the Memory page's
  # longer one: a slow node must not hold the sampler for long.
  defp read_memory(node) do
    with {:ok, snap} <- Target.rpc(node, :beamdash_agent, :memory_snapshot, []),
         {:ok, tables} <- Target.rpc(node, :beamdash_agent, :ets_tables, []) do
      {:ok, snap, tables}
    end
  end

  defp fresh(node) do
    %{
      node: node,
      prev_sample: %{},
      prev_at: nil,
      streaks: %{},
      last_log_id: 0
    }
  end

  defp run(state) do
    episodes = AnomalyMonitor.history(state.monitor, clear: true)
    if Settings.snapshots_enabled?(), do: write(state.store, :anomalies, episode_rows(episodes))

    case state.source.status.() do
      %{status: :connected, node: node} -> sample(state, to_string(node))
      _ -> state
    end
  end

  defp sample(state, node) do
    state = if state.node == node, do: state, else: Map.merge(state, fresh(node))

    if Settings.snapshots_enabled?() do
      state =
        case state.source.processes.() do
          {:ok, procs} -> record(state, procs)
          _ -> state
        end

      record_memory(state, node)
    else
      record_logs(%{state | prev_sample: %{}, prev_at: nil, streaks: %{}})
    end
  end

  defp record_memory(state, node) do
    case state.source.memory.(node) do
      {:ok, snap, tables} ->
        write(state.store, :memory, [memory_row(node, snap, tables)])

      _ ->
        :ok
    end

    state
  end

  defp memory_row(node, snap, tables) do
    %{
      at: System.system_time(:millisecond),
      node: node,
      data: %{
        memory: snap.memory,
        atom_count: snap.atom_count,
        ets_count: snap.ets_count,
        tables:
          tables
          |> Enum.sort_by(& &1.memory, :desc)
          |> Enum.take(@top_tables)
          |> Enum.map(&table/1)
      }
    }
  end

  defp table(t) do
    %{
      name: text(t.name),
      named: t.named,
      type: text(t.type),
      size: t.size,
      memory: t.memory,
      owner: text(t.owner_name)
    }
  end

  defp text(nil), do: nil
  defp text(value) when is_atom(value), do: Atom.to_string(value)
  defp text(value) when is_binary(value), do: value
  defp text(value), do: inspect(value)

  defp record(state, procs) do
    source = state.source

    details = fn pid ->
      case source.details.(pid, 0) do
        {:ok, details} when is_map(details) -> details
        _ -> nil
      end
    end

    {state, rows} =
      observe(
        state,
        procs,
        System.system_time(:millisecond),
        System.monotonic_time(:microsecond),
        details
      )

    write(state.store, :snapshots, rows)
    record_logs(state)
  end

  defp record_logs(state) do
    {state, log_rows} = new_logs(state, state.source.logs.())
    write(state.store, :logs, log_rows)
    state
  end

  defp episode_rows(episodes) do
    for episode <- episodes do
      %{
        at: episode.started_at,
        node: episode.node,
        pid: episode.pid,
        measure: episode.measure,
        data: Map.take(episode, [:kind, :text, :last_at, :duration_ms, :samples, :score, :now])
      }
    end
  end

  defp attention(procs, rates, streaks) do
    load = procs |> Enum.filter(&(rate(rates, &1.pid) > 0)) |> top(&rate(rates, &1.pid))
    memory = top(procs, & &1.memory)
    rising = procs |> Enum.filter(&rising?(streaks, &1.pid)) |> top(& &1.memory)

    for {reason, pids} <- [load: load, memory: memory, heap_rising: rising],
        pid <- pids,
        do: {pid, reason}
  end

  defp top(procs, fun) do
    procs
    |> Enum.sort_by(fun, :desc)
    |> Enum.take(@top)
    |> Enum.map(& &1.pid)
  end

  defp rate(rates, pid), do: rates[pid] || 0

  # consecutive samples in which the memory went up: {last memory, count}
  defp streaks(procs, previous) do
    Map.new(procs, fn proc ->
      count =
        case previous[proc.pid] do
          {last, n} when proc.memory > last -> n + 1
          _ -> 0
        end

      {proc.pid, {proc.memory, count}}
    end)
  end

  defp rising?(streaks, pid), do: match?({_, n} when n >= @rising, streaks[pid])

  defp new_logs(state, entries) do
    fresh = entries |> Enum.filter(&(&1.id > state.last_log_id)) |> Enum.sort_by(& &1.id)

    rows =
      for entry <- fresh do
        %{
          at: log_ms(entry.at),
          node: state.node,
          level: entry.level,
          data: Map.drop(entry, [:at, :level])
        }
      end

    last_log_id = Enum.reduce(fresh, state.last_log_id, &max(&1.id, &2))
    {%{state | last_log_id: last_log_id}, rows}
  end

  defp log_ms(%DateTime{} = at), do: DateTime.to_unix(at, :millisecond)
  defp log_ms(_), do: System.system_time(:millisecond)

  defp write(_store, _kind, []), do: :ok
  defp write(store, kind, rows), do: Store.record(kind, rows, store)

  defp schedule(:infinity), do: :ok
  defp schedule(ms), do: Process.send_after(self(), :tick, ms)
end
