defmodule Beamdash.Insights.Anomaly do
  @moduledoc """
  Processes that behave unlike themselves or unlike their peers, found
  with Nx over every sampled process at once (no model is asked).

  `track/4` keeps a rolling history of the busiest processes (by memory,
  queue and reductions rate). `detect/3` then scores, per process and per
  measure (memory, queue, reductions rate, in log space):

    * **shift**: the level changed and stayed changed (the strongest split
      of the series, by t statistic, `Beamdash.Insights.Series.change_point/3`);
    * **rising**: a steady climb over the window (a straight line fits
      well and the rise is large);
    * **spike**: the latest sample is far above the rest;
    * **peer outlier**: far above processes of the same kind (OTP
      behaviour, or initial call) right now, by median absolute deviation.

  Thresholds keep the list short: a finding needs both a strong statistic
  and a change of at least half again (or a queue of #{10} messages or more).
  """
  alias Beamdash.Insights.Series

  @keep 60
  @per_measure 80
  @min_points 8
  @min_peers 5

  # log(1.5): a change of at least 50%
  @min_change :math.log(1.5)

  @doc "Samples kept per process (the window is this many refreshes)."
  def keep, do: @keep

  @doc """
  Adds a sample of `procs` (`Beamdash.Target.processes/0`) with their
  reductions `rates` taken at `at_us`, keeping the top #{@per_measure}
  processes by each measure and their last #{@keep} points.
  """
  def track(history, procs, rates, at_us) do
    history = history || %{samples: [], procs: %{}}
    ids = candidates(procs, rates)
    by_pid = Map.new(procs, &{&1.pid, &1})

    points =
      Map.new(ids, fn pid ->
        p = by_pid[pid]
        point = %{at_us: at_us, memory: p.memory, queue: p.message_queue_len, rate: rates[pid]}
        {pid, Enum.take(Map.get(history.procs, pid, []) ++ [point], -@keep)}
      end)

    %{samples: Enum.take(history.samples ++ [at_us], -@keep), procs: points}
  end

  defp candidates(procs, rates) do
    top = fn f ->
      procs |> Enum.sort_by(f, :desc) |> Enum.take(@per_measure) |> Enum.map(& &1.pid)
    end

    (top.(& &1.memory) ++ top.(&(&1.message_queue_len || 0)) ++ top.(&(rates[&1.pid] || 0)))
    |> Enum.uniq()
  end

  @doc "`{:ready, seconds}` once there are enough samples, else `{:collecting, s, needed}`."
  def readiness(%{samples: [first | _] = samples}) when length(samples) >= @min_points,
    do: {:ready, div(List.last(samples) - first, 1_000_000)}

  def readiness(%{samples: samples}), do: {:collecting, length(samples), @min_points}
  def readiness(_), do: {:collecting, 0, @min_points}

  @doc """
  Findings, strongest first: `[%{pid, measure, kind, score, now, before,
  since_s, text}]`, at most one per process and measure. `procs` are the
  current processes (for the peer comparison and names).
  """
  def detect(history, procs, rates) do
    (series_findings(history) ++ peer_findings(procs, rates))
    |> Enum.group_by(&{&1.pid, &1.measure})
    |> Enum.map(fn {_, fs} -> Enum.max_by(fs, & &1.score) end)
    |> Enum.sort_by(& &1.score, :desc)
  end

  ## Over time

  @measures [:memory, :queue, :rate]

  defp series_findings(%{samples: samples, procs: procs}) when length(samples) >= @min_points do
    t0 = hd(samples)

    tracked =
      procs
      |> Enum.filter(fn {_pid, points} -> length(points) >= @min_points end)
      |> Enum.sort_by(&elem(&1, 0))

    if tracked == [] do
      []
    else
      Enum.flat_map(@measures, &measure_findings(&1, tracked, t0))
    end
  end

  defp series_findings(_), do: []

  defp measure_findings(measure, tracked, t0) do
    series =
      Enum.map(tracked, fn {_pid, points} ->
        Enum.map(points, fn p ->
          {(p.at_us - t0) / 1_000_000, Series.slog(Map.get(p, measure))}
        end)
      end)

    {ts, ys, mask} = Series.batch(series)
    trend = Series.trend(ts, ys, mask)
    cp = Series.change_point(ys, mask)
    z = Series.last_z(ys, mask)

    span =
      Nx.subtract(
        Nx.reduce_max(ts, axes: [1]),
        Nx.reduce_min(Nx.select(mask, ts, 1.0e9), axes: [1])
      )

    rows =
      Enum.zip([
        tracked,
        Nx.to_flat_list(trend.slope),
        Nx.to_flat_list(trend.r2),
        Nx.to_flat_list(cp.score),
        Nx.to_flat_list(cp.index),
        Nx.to_flat_list(cp.before),
        Nx.to_flat_list(cp.after),
        Nx.to_flat_list(z),
        Nx.to_flat_list(span),
        Nx.to_list(ts)
      ])

    Enum.flat_map(rows, fn {{pid, points}, slope, r2, cp_score, cp_index, before, after_, z, span,
                            t_row} ->
      last = List.last(points)
      first = hd(points)
      now = Map.get(last, measure)

      cond do
        not big_enough?(measure, now) ->
          []

        r2 >= 0.8 and slope > 0 and slope * span >= @min_change ->
          [
            finding(
              pid,
              measure,
              :rising,
              2 + 10 * r2 * min(slope * span, 3.0),
              now,
              Map.get(first, measure),
              round(span),
              "rising steadily over #{round(span)} s (r² #{Float.round(r2, 2)})"
            )
          ]

        cp_score >= 6 and after_ - before >= @min_change ->
          at = Enum.at(t_row, cp_index) || 0.0
          since = round(List.last(t_row) - at)

          [
            finding(
              pid,
              measure,
              :shift,
              cp_score,
              now,
              unlog(before),
              since,
              "jumped from about #{show(measure, unlog(before))} #{since} s ago and stayed"
            )
          ]

        z >= 6 and Series.slog(now) - before >= @min_change ->
          [
            finding(
              pid,
              measure,
              :spike,
              z,
              now,
              nil,
              0,
              "spiked in the latest sample (z #{round(z)})"
            )
          ]

        true ->
          []
      end
    end)
  end

  # a small queue or a near-idle rate moving is not worth showing
  defp big_enough?(:queue, now), do: is_number(now) and now >= 10
  defp big_enough?(:rate, now), do: is_number(now) and now >= 1_000
  defp big_enough?(:memory, now), do: is_number(now) and now >= 100_000

  ## Against peers

  defp peer_findings(procs, rates) do
    procs
    |> Enum.group_by(&peer_group/1)
    |> Enum.filter(fn {group, members} -> group != nil and length(members) >= @min_peers end)
    |> Enum.flat_map(fn {group, members} ->
      Enum.flat_map(@measures, fn measure ->
        values = Enum.map(members, &(value(&1, measure, rates) || 0))
        z = values |> Enum.map(&Series.slog/1) |> Nx.tensor(type: :f32) |> Series.robust_z()
        median = values |> Enum.sort() |> Enum.at(div(length(values), 2))

        members
        |> Enum.zip(Enum.zip(values, Nx.to_flat_list(z)))
        |> Enum.filter(fn {_p, {v, z}} ->
          z >= 5 and big_enough?(measure, v) and v >= 10 * max(median, 1)
        end)
        |> Enum.map(fn {p, {v, z}} ->
          finding(
            p.pid,
            measure,
            :peer_outlier,
            z,
            v,
            median,
            nil,
            "#{ratio(v, median)}× the median of #{length(members)} #{group_name(group)} processes"
          )
        end)
      end)
    end)
  end

  defp value(p, :memory, _rates), do: p.memory
  defp value(p, :queue, _rates), do: p.message_queue_len
  defp value(p, :rate, rates), do: rates[p.pid]

  # Processes are compared with others of the same OTP behaviour started
  # from the same module: workers of one pool, connections of one listener.
  # A spawned fun's initial call (erlang:apply/2, proc_lib:init_p) says
  # nothing about what the process does, so those have no peers.
  @generic_calls [{:erlang, :apply, 2}, {:proc_lib, :init_p, 3}, {:proc_lib, :init_p, 5}]

  defp peer_group(%{initial_call: mfa}) when mfa in @generic_calls, do: nil
  defp peer_group(%{kind: kind, initial_call: {m, _, _}}) when kind != nil, do: {kind, m}
  defp peer_group(%{initial_call: {m, f, a}}), do: {nil, {m, f, a}}
  defp peer_group(_), do: nil

  defp group_name({nil, mfa}), do: Beamdash.Format.mfa(mfa)
  defp group_name({kind, m}), do: "#{kind} #{Beamdash.Format.name(m)}"

  ## Shared

  defp finding(pid, measure, kind, score, now, before, since_s, text) do
    %{
      pid: pid,
      measure: measure,
      kind: kind,
      score: Float.round(score * 1.0, 1),
      now: now,
      before: before,
      since_s: since_s,
      text: text
    }
  end

  defp unlog(x), do: round(:math.exp(x) - 1)

  defp ratio(v, median), do: round(v / max(median, 1))

  @doc "A value of `measure` as shown: bytes, messages or reductions/s."
  def show(:memory, v), do: Beamdash.Format.bytes(v)
  def show(:queue, v), do: "#{v} messages"
  def show(:rate, v), do: "#{Beamdash.Format.number(v)} reductions/s"
end
