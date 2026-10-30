defmodule Beamdash.Insights.Forecast do
  @moduledoc """
  Where the node's memory and system limits are heading, for the Memory
  tab: a straight line (`Scholar.Linear.LinearRegression`) through each
  measure's recent history, how well it fits (R²), the value an hour from
  now, and for the atom, process and ETS table counts, when the line
  reaches the node's limit.

  A trend is only reported when the line fits (R² ≥ #{0.6}) and the
  measure would grow by at least #{5}% in an hour: short histories and
  noisy measures say nothing.
  """
  alias Scholar.Linear.LinearRegression

  @min_points 10
  @min_window_s 30
  @min_r2 0.6
  @min_growth_per_hour 0.05

  @memory [
    {:total, "Total memory"},
    {:processes, "Processes"},
    {:binary, "Binaries"},
    {:ets, "ETS"},
    {:atom, "Atoms (bytes)"},
    {:code, "Code"}
  ]

  @counts [
    {:atom_count, :atom_limit, "Atoms"},
    {:process_count, :process_limit, "Processes (count)"},
    {:ets_count, :ets_limit, "ETS tables"}
  ]

  @doc """
  `{:ok, [forecast]}` from the Memory tab's `history` (`[%{at: ms,
  memory: map, counts: map}]`, oldest first) and the latest snapshot
  `snap` (for the limits), or `{:collecting, s, needed_s}` while the
  history is too short. A forecast is `%{key, label, now, per_min, r2,
  in_1h, limit, limit_in_s, growing}`; `limit` and `limit_in_s` only for
  counts.
  """
  def forecast(history, snap) do
    window_s = window_s(history)

    if length(history) < @min_points or window_s < @min_window_s do
      {:collecting, round(window_s), @min_window_s}
    else
      t0 = hd(history).at
      ts = Enum.map(history, &((&1.at - t0) / 1000))

      memory =
        for {key, label} <- @memory,
            ys = Enum.map(history, &part(&1.memory, key)),
            Enum.all?(ys, &is_number/1) do
          line(key, label, ts, ys, nil)
        end

      counts =
        for {key, limit_key, label} <- @counts,
            ys = Enum.map(history, &get_in(&1, [:counts, key])),
            Enum.all?(ys, &is_number/1) do
          line(key, label, ts, ys, snap && Map.get(snap, limit_key))
        end

      {:ok, memory ++ counts}
    end
  end

  defp window_s([]), do: 0
  defp window_s(history), do: (List.last(history).at - hd(history).at) / 1000

  defp part(memory, :total), do: memory[:total]
  defp part(memory, key), do: memory[key]

  defp line(key, label, ts, ys, limit) do
    x = Nx.tensor(ts, type: :f64) |> Nx.new_axis(1)
    y = Nx.tensor(ys, type: :f64)
    now = List.last(ys)

    {slope, r2} =
      if Enum.uniq(ys) == [now] do
        {0.0, 0.0}
      else
        model = LinearRegression.fit(x, y)
        pred = LinearRegression.predict(model, x)

        {model.coefficients |> Nx.reshape({}) |> Nx.to_number(),
         Scholar.Metrics.Regression.r2_score(y, pred) |> Nx.to_number()}
      end

    in_1h = now + slope * 3600
    growing = r2 >= @min_r2 and slope > 0 and slope * 3600 >= @min_growth_per_hour * max(now, 1)

    %{
      key: key,
      label: label,
      now: now,
      per_min: slope * 60,
      r2: Float.round(r2 * 1.0, 2),
      in_1h: round(in_1h),
      limit: limit,
      limit_in_s:
        if(growing and is_number(limit) and limit > now, do: round((limit - now) / slope)),
      growing: growing
    }
  end
end
