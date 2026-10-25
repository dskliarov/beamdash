defmodule Beamdash.Load do
  @moduledoc """
  Observer's Load Charts: scheduler utilization, memory usage and IO,
  sampled on the target twice a second (Observer's default) by
  `beamdash_agent:load_sampler_start/2`, kept for the last 60 s.

  Utilization is computed as Observer does: per scheduler, the change in
  active time over the change in total time between two samples, from
  `erlang:statistics(scheduler_wall_time)` (normal and dirty CPU
  schedulers). IO is the change in `erlang:statistics(io)`, per second.
  """

  alias Beamdash.Target

  @interval_ms 500
  @window_ms 60_000
  @memory_kinds [:total, :processes, :atom, :binary, :code, :ets]

  def interval_ms, do: @interval_ms
  def window_ms, do: @window_ms
  def memory_kinds, do: @memory_kinds

  @doc "Starts a sampler on `node` that sends `{:beamdash_load, sampler, sample}` to `receiver`."
  def start(node, receiver \\ self()) do
    case Target.rpc(node, :beamdash_agent, :load_sampler_start, [receiver, @interval_ms]) do
      {:ok, {:ok, pid}} -> {:ok, pid}
      {:ok, other} -> {:error, other}
      error -> error
    end
  end

  def stop(sampler) when is_pid(sampler) do
    send(sampler, :stop)
    :ok
  end

  def stop(_), do: :ok

  @doc "Empty history."
  def new, do: %{prev: nil, points: [], schedulers: 0, dirty: 0}

  @doc """
  Adds a sample. Each point is `%{at_ms, util: [percent per scheduler] |
  nil, memory: %{kind => bytes}, io: {input_per_s, output_per_s}}`.
  When the schedulers change, the history starts again, as in Observer.
  """
  def add(%{prev: nil} = state, sample), do: %{state | prev: sample} |> sizes(sample)

  def add(%{prev: prev} = state, sample) do
    dt = max(sample.at_ms - prev.at_ms, 1)

    case utilization(prev.scheduler_wall_time, sample.scheduler_wall_time) do
      :changed ->
        new() |> add(sample)

      util ->
        point = %{
          at_ms: sample.at_ms,
          util: util,
          memory: Map.take(sample.memory, @memory_kinds),
          io:
            {per_s(sample.io_input - prev.io_input, dt),
             per_s(sample.io_output - prev.io_output, dt)}
        }

        cutoff = sample.at_ms - @window_ms
        points = Enum.drop_while(state.points ++ [point], &(&1.at_ms < cutoff))
        %{state | prev: sample, points: points} |> sizes(sample)
    end
  end

  defp sizes(state, sample),
    do: %{state | schedulers: sample.schedulers, dirty: sample[:dirty_cpu_schedulers] || 0}

  @doc false
  # Observer's calc_delta: 100 * Δactive / Δtotal per scheduler
  def utilization(nil, _), do: nil
  def utilization(_, nil), do: nil
  def utilization(:undefined, _), do: nil
  def utilization(_, :undefined), do: nil

  def utilization(prev, now) do
    prev = Enum.sort(prev)
    now = Enum.sort(now)

    if Enum.map(prev, &elem(&1, 0)) == Enum.map(now, &elem(&1, 0)) do
      Enum.zip_with(prev, now, fn {_, a0, t0}, {_, a1, t1} ->
        if t1 > t0, do: min(100.0, 100 * (a1 - a0) / (t1 - t0)), else: 0.0
      end)
    else
      :changed
    end
  end

  defp per_s(delta, dt_ms), do: max(delta, 0) * 1000 / dt_ms
end
