defmodule Beamdash.ProcessStats do
  @moduledoc """
  Rates from successive samples. The target only reports running totals
  (reductions since the process started), so "how busy is it now" is the
  difference between two samples divided by the time between them.
  """

  @history 60

  @doc """
  Reductions per second for every process in `procs`, given the previous
  sample `prev` (`%{pid => reductions}`) taken `elapsed_us` microseconds
  earlier. Processes new since the last sample get `nil`.

  Returns `{rates, sample}`: `%{pid => reds_per_sec | nil}` and the sample
  to pass in next time.
  """
  def table_rates(procs, prev, elapsed_us) do
    sample = Map.new(procs, &{&1.pid, &1.reductions})

    rates =
      Map.new(procs, fn %{pid: pid, reductions: reds} ->
        {pid, rate(prev[pid], reds, elapsed_us)}
      end)

    {rates, sample}
  end

  defp rate(nil, _now, _elapsed_us), do: nil
  defp rate(_before, _now, elapsed_us) when elapsed_us <= 0, do: nil
  defp rate(before, now, _elapsed_us) when now < before, do: nil
  defp rate(before, now, elapsed_us), do: round((now - before) * 1_000_000 / elapsed_us)

  @doc """
  Adds a detail sample to a history (newest last, at most #{@history}).
  Each point is `%{at_us, reductions, reds_per_sec, memory, message_queue_len}`;
  the rate is computed against the previous point.
  """
  def push(history, %{sampled_at_us: at, reductions: reds} = details) do
    rate =
      case List.last(history) do
        %{at_us: prev_at, reductions: prev_reds} -> rate(prev_reds, reds, at - prev_at)
        nil -> nil
      end

    point = %{
      at_us: at,
      reductions: reds,
      reds_per_sec: rate,
      memory: details.memory.total,
      message_queue_len: details.mailbox.length
    }

    Enum.take(history ++ [point], -@history)
  end
end
