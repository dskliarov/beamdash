defmodule Beamdash.Insights.Series do
  @moduledoc """
  Nx statistics over many time series at once, for `Beamdash.Insights`.

  A batch is a `{n, t}` tensor of values with a `{n, t}` mask (1 where a
  value was sampled, 0 for padding), so series of different lengths are
  handled together: process histories start when a process enters the
  sampled set. `ts` is the `{n, t}` sample times in seconds.
  """
  import Nx.Defn

  @doc """
  Least-squares line through each masked series: `%{slope, intercept, r2}`,
  each `{n}`. A series with fewer than two points gets slope 0 and r2 0.
  """
  defn trend(ts, ys, mask) do
    n = Nx.sum(mask, axes: [1])
    safe_n = Nx.max(n, 1)
    t_mean = Nx.sum(ts * mask, axes: [1]) / safe_n
    y_mean = Nx.sum(ys * mask, axes: [1]) / safe_n
    dt = (ts - Nx.new_axis(t_mean, 1)) * mask
    dy = (ys - Nx.new_axis(y_mean, 1)) * mask
    sxx = Nx.sum(dt * dt, axes: [1])
    sxy = Nx.sum(dt * dy, axes: [1])
    syy = Nx.sum(dy * dy, axes: [1])
    ok = n >= 2 and sxx > 0
    slope = Nx.select(ok, sxy / Nx.max(sxx, 1.0e-12), 0.0)
    r2 = Nx.select(ok and syy > 0, sxy * sxy / Nx.max(sxx * syy, 1.0e-12), 0.0)
    %{slope: slope, intercept: y_mean - slope * t_mean, r2: r2}
  end

  @doc """
  The strongest change of level in each series: for every split point,
  the t statistic of the difference between the mean before and after it
  (at least `min_side` points on each side), and the best split.
  Returns `%{score, index, before, after}`, each `{n}`; `index` is the
  first sample of the new level. `floor` is the smallest standard
  deviation assumed, so a flat series that moves a little is not
  infinitely surprising.
  """
  defn change_point(ys, mask, opts \\ []) do
    opts = keyword!(opts, min_side: 3, floor: 0.05)
    min_side = opts[:min_side]
    floor = opts[:floor]

    x = ys * mask
    c = Nx.cumulative_sum(mask, axis: 1)
    s = Nx.cumulative_sum(x, axis: 1)
    s2 = Nx.cumulative_sum(x * x, axis: 1)
    total_c = c[[.., -1..-1//1]]
    total_s = s[[.., -1..-1//1]]
    total_s2 = s2[[.., -1..-1//1]]

    # split after position k: [0..k] before, (k..] after
    cb = c
    ca = total_c - c
    mb = s / Nx.max(cb, 1)
    ma = (total_s - s) / Nx.max(ca, 1)
    ss = total_s2 - cb * mb * mb - ca * ma * ma
    var = Nx.max(ss / Nx.max(total_c - 2, 1), floor * floor)
    se = Nx.sqrt(var / Nx.max(cb, 1) + var / Nx.max(ca, 1))
    valid = cb >= min_side and ca >= min_side and mask == 1
    t = Nx.select(valid, Nx.abs(ma - mb) / se, 0.0)

    k = Nx.argmax(t, axis: 1)

    pick = fn tensor ->
      Nx.take_along_axis(tensor, Nx.new_axis(k, 1), axis: 1) |> Nx.squeeze(axes: [1])
    end

    %{score: pick.(t), index: k + 1, before: pick.(mb), after: pick.(ma)}
  end

  @doc """
  How far each series' last value is above the rest: `(last − mean) / sd`
  of the earlier masked points (sd at least `floor`), `{n}`.
  """
  defn last_z(ys, mask, opts \\ []) do
    opts = keyword!(opts, floor: 0.05)
    t = Nx.axis_size(ys, 1)

    earlier =
      Nx.concatenate([mask[[.., 0..(t - 2)//1]], Nx.broadcast(0.0, {Nx.axis_size(ys, 0), 1})],
        axis: 1
      )

    n = Nx.max(Nx.sum(earlier, axes: [1]), 1)
    mean = Nx.sum(ys * earlier, axes: [1]) / n
    var = Nx.sum((ys - Nx.new_axis(mean, 1)) ** 2 * earlier, axes: [1]) / n
    sd = Nx.max(Nx.sqrt(var), opts[:floor])
    (ys[[.., -1]] - mean) / sd
  end

  @doc """
  Robust z scores of `values` (`{n}`) against their median and median
  absolute deviation (scaled to a standard deviation, at least `floor`).
  """
  def robust_z(values, floor \\ 0.25) do
    median = Nx.median(values)
    mad = values |> Nx.subtract(median) |> Nx.abs() |> Nx.median() |> Nx.multiply(1.4826)
    Nx.divide(Nx.subtract(values, median), Nx.max(mad, floor))
  end

  @doc "Signed `log1p`, so byte counts and rates of very different sizes compare."
  def slog(nil), do: 0.0
  def slog(x) when x >= 0, do: :math.log(1 + x)
  def slog(x), do: -:math.log(1 - x)

  @doc """
  Pads lists of `{t_seconds, value}` points (oldest first) on the left to
  one length: `{ts, ys, mask}` tensors of `{n, longest}`.
  """
  def batch(series) do
    longest = series |> Enum.map(&length/1) |> Enum.max(fn -> 1 end) |> max(1)

    {ts, ys, ms} =
      series
      |> Enum.map(fn points ->
        pad = longest - length(points)
        {first_t, _} = List.first(points, {0.0, 0.0})

        {List.duplicate(first_t, pad) ++ Enum.map(points, &(elem(&1, 0) * 1.0)),
         List.duplicate(0.0, pad) ++ Enum.map(points, &(elem(&1, 1) * 1.0)),
         List.duplicate(0.0, pad) ++ List.duplicate(1.0, length(points))}
      end)
      |> unzip3()

    {Nx.tensor(ts, type: :f32), Nx.tensor(ys, type: :f32), Nx.tensor(ms, type: :f32)}
  end

  defp unzip3(triples) do
    {Enum.map(triples, &elem(&1, 0)), Enum.map(triples, &elem(&1, 1)),
     Enum.map(triples, &elem(&1, 2))}
  end
end
