defmodule Beamdash.AnomalyMonitor do
  @moduledoc """
  Checks the connected node's processes for anomalies every two seconds while
  something watches it (`watch/2`), with `Beamdash.Insights.Anomaly` once enough
  samples are in.

  A finding that repeats in consecutive checks is one episode. It stays open
  until a check no longer flags it, then moves to the history. `current/1`
  returns the latest check, `history/2` the closed episodes, and
  `history(server, clear: true)` also removes them. A disconnect, a node
  change, or the last watcher leaving closes the open episodes, tagged with the
  node they were seen on.
  """

  use GenServer

  alias Beamdash.{ProcessStats, Target}
  alias Beamdash.Insights.Anomaly

  @interval 2_000
  @max_findings 20
  @max_closed 2_000

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The latest check: `%{readiness, findings, checked_at, tracked}`."
  def current(server \\ __MODULE__), do: GenServer.call(server, :current)

  @doc "Closed episodes, oldest first. `clear: true` also removes them."
  def history(server \\ __MODULE__, opts \\ []),
    do: GenServer.call(server, {:history, Keyword.get(opts, :clear, false)})

  @doc "Checks now."
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick, :infinity)

  @doc "Keeps checks running while `pid` is alive. Checks stop when the last watcher exits."
  def watch(server \\ __MODULE__, pid \\ self()), do: GenServer.call(server, {:watch, pid})

  @impl true
  def init(opts) do
    state =
      Map.merge(fresh(nil), %{
        closed: [],
        interval: Keyword.get(opts, :interval, @interval),
        source: Map.merge(default_source(), Map.new(Keyword.get(opts, :source, %{}))),
        watchers: %{},
        timer: nil
      })

    {:ok, state}
  end

  @impl true
  def handle_call(:current, _from, state) do
    current = %{
      readiness: Anomaly.readiness(state.history),
      findings: state.findings,
      checked_at: state.checked_at,
      tracked: tracked(state.history)
    }

    {:reply, current, state}
  end

  def handle_call({:history, clear?}, _from, state) do
    episodes = Enum.sort_by(state.closed, & &1.started_at)
    {:reply, episodes, if(clear?, do: %{state | closed: []}, else: state)}
  end

  def handle_call(:tick, _from, state), do: {:reply, :ok, run(state)}

  def handle_call({:watch, pid}, _from, state) do
    ref = Process.monitor(pid)
    state = %{state | watchers: Map.put(state.watchers, ref, pid)}
    state = if state.timer, do: state, else: arm(state, 0)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:tick, timer}, %{timer: timer} = state) do
    {:noreply, state |> Map.put(:timer, nil) |> run() |> reschedule()}
  end

  def handle_info({:tick, _stale}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    watchers = Map.delete(state.watchers, ref)
    state = %{state | watchers: watchers}
    {:noreply, if(map_size(watchers) == 0, do: pause(state), else: state)}
  end

  defp default_source do
    %{
      status: &Target.status/0,
      processes: &Target.processes/0,
      clock: fn -> {System.system_time(:millisecond), System.monotonic_time(:microsecond)} end
    }
  end

  defp fresh(node) do
    %{
      node: node,
      open: %{},
      prev_sample: %{},
      prev_at: nil,
      history: nil,
      findings: [],
      checked_at: nil
    }
  end

  defp run(state) do
    case state.source.status.() do
      %{status: :connected, node: node} -> state |> switch(to_string(node)) |> check()
      _ -> switch(state, nil)
    end
  end

  defp switch(%{node: node} = state, node), do: state

  defp switch(state, node) do
    state
    |> retire(Map.values(state.open))
    |> Map.merge(fresh(node))
  end

  defp check(state) do
    case state.source.processes.() do
      {:ok, procs} -> observe(state, procs, state.source.clock.())
      _ -> state
    end
  end

  defp observe(state, procs, {now_ms, now_us}) do
    elapsed = if state.prev_at, do: now_us - state.prev_at, else: 0
    {rates, prev_sample} = ProcessStats.table_rates(procs, state.prev_sample, elapsed)

    history =
      if state.prev_at,
        do: Anomaly.track(state.history, procs, rates, now_us),
        else: state.history

    findings =
      if match?({:ready, _}, Anomaly.readiness(history)),
        do: history |> Anomaly.detect(procs, rates) |> Enum.take(@max_findings),
        else: []

    %{
      state
      | prev_sample: prev_sample,
        prev_at: now_us,
        history: history,
        findings: findings,
        checked_at: DateTime.from_unix!(now_ms, :millisecond)
    }
    |> track_episodes(now_ms)
  end

  defp track_episodes(state, now_ms) do
    flagged = Map.new(state.findings, &{{&1.pid, &1.measure}, &1})
    {kept, ended} = Enum.split_with(state.open, fn {key, _} -> Map.has_key?(flagged, key) end)
    open = Map.new(kept, fn {key, episode} -> {key, extend(episode, flagged[key], now_ms)} end)

    open =
      Enum.reduce(flagged, open, fn {key, finding}, acc ->
        Map.put_new_lazy(acc, key, fn -> start(finding, state.node, now_ms) end)
      end)

    state
    |> Map.put(:open, open)
    |> retire(Enum.map(ended, &elem(&1, 1)))
  end

  defp retire(state, episodes) do
    closed = Enum.map(episodes, &finish/1) ++ state.closed
    %{state | closed: Enum.take(closed, @max_closed)}
  end

  defp start(finding, node, now_ms) do
    %{
      pid: finding.pid,
      measure: finding.measure,
      node: node,
      started_at: now_ms,
      last_at: now_ms,
      samples: 1,
      kind: finding.kind,
      text: finding.text,
      score: finding.score,
      now: finding.now
    }
  end

  defp extend(episode, finding, now_ms) do
    %{
      episode
      | last_at: now_ms,
        samples: episode.samples + 1,
        kind: finding.kind,
        text: finding.text,
        score: max(episode.score, finding.score),
        now: finding.now
    }
  end

  defp finish(episode), do: Map.put(episode, :duration_ms, episode.last_at - episode.started_at)

  defp tracked(%{procs: procs}), do: map_size(procs)
  defp tracked(_), do: 0

  defp pause(state) do
    state
    |> retire(Map.values(state.open))
    |> Map.merge(fresh(state.node))
    |> Map.put(:timer, nil)
  end

  defp reschedule(state) do
    if map_size(state.watchers) > 0, do: arm(state, state.interval), else: state
  end

  defp arm(state, :infinity), do: %{state | timer: nil}

  defp arm(state, ms) do
    token = make_ref()
    Process.send_after(self(), {:tick, token}, ms)
    %{state | timer: token}
  end
end
