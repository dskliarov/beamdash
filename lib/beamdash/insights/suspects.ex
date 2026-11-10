defmodule Beamdash.Insights.Suspects do
  @moduledoc """
  Marks the processes most likely at fault in the stored snapshots, with no
  labels to learn from.

  Each snapshot row is a point of three log-scale features: memory, mailbox
  length and reductions rate. k-means (`Scholar.Cluster.KMeans`) splits the
  rows into peer groups, so a busy worker is compared with busy workers. A
  row's score is its largest robust z-score above its group's typical value
  (median and median absolute deviation, per feature). A row is a suspect
  when its score reaches `@threshold`.
  """
  alias Beamdash.Insights.Series

  @min_rows 20
  @groups 3
  @min_group 20
  @threshold 3.5
  @min_scale 0.5
  @top 10

  @doc """
  `analyze(rows)` takes snapshot rows from `Beamdash.Store` (`at`, `pid`,
  `data`) and returns `%{rows, flagged, suspects}`: `rows` is how many were
  compared, `flagged` maps `{at, pid}` to the score of each suspect row, and
  `suspects` lists up to #{@top} processes, most flagged snapshots first, each
  as `%{pid, name, snapshots, score, feature, memory, queue, rate}`.
  """
  def analyze(rows) when length(rows) < @min_rows,
    do: %{rows: length(rows), flagged: %{}, suspects: []}

  def analyze(rows) do
    points = Enum.map(rows, &point/1)
    x = points |> Nx.tensor(type: :f32) |> standardize()

    model =
      Scholar.Cluster.KMeans.fit(x,
        num_clusters: @groups,
        num_runs: 3,
        max_iterations: 50,
        key: Nx.Random.key(42)
      )

    labels = Nx.to_flat_list(model.labels)
    scored = score(Enum.zip([rows, points, labels]))
    flagged = for {row, s} <- scored, s.score >= @threshold, into: %{}, do: {{row.at, row.pid}, s}

    %{rows: length(rows), flagged: flagged, suspects: suspects(scored, flagged)}
  end

  defp point(row) do
    process = row.data["process"] || %{}

    [
      Series.slog(process["memory"] || 0),
      Series.slog(process["message_queue_len"] || 0),
      Series.slog(row.data["rate"] || 0)
    ]
  end

  # columns to mean 0 and sd 1, so no feature dominates the distances
  defp standardize(x) do
    mean = Nx.mean(x, axes: [0])
    sd = x |> Nx.standard_deviation(axes: [0]) |> Nx.max(1.0e-6)
    x |> Nx.subtract(mean) |> Nx.divide(sd)
  end

  defp score(entries) do
    by_label = Enum.group_by(entries, fn {_row, _point, label} -> label end)
    everyone = stats(Enum.map(entries, fn {_row, point, _label} -> point end))

    peers =
      Map.new(by_label, fn {label, members} ->
        if length(members) >= @min_group,
          do: {label, stats(Enum.map(members, fn {_row, point, _label} -> point end))},
          else: {label, everyone}
      end)

    for {row, point, label} <- entries do
      {score, feature} = best_z(point, Map.fetch!(peers, label))
      {row, %{score: score, feature: feature}}
    end
  end

  # per feature: the median and the scale (median absolute deviation, floored)
  defp stats(points) do
    points
    |> Enum.zip()
    |> Enum.map(fn column ->
      column = Tuple.to_list(column)
      med = median(column)
      mad = column |> Enum.map(&abs(&1 - med)) |> median()
      {med, max(1.4826 * mad, @min_scale)}
    end)
  end

  defp best_z(point, stats) do
    point
    |> Enum.zip(stats)
    |> Enum.with_index()
    |> Enum.map(fn {{v, {med, scale}}, i} -> {(v - med) / scale, i} end)
    |> Enum.max_by(&elem(&1, 0))
    |> then(fn {z, i} -> {max(z, 0.0), Enum.at(~w(memory queue rate)a, i)} end)
  end

  defp suspects(scored, flagged) do
    scored
    |> Enum.filter(fn {row, _} -> Map.has_key?(flagged, {row.at, row.pid}) end)
    |> Enum.group_by(fn {row, _} -> row.pid end)
    |> Enum.map(fn {pid, items} ->
      {worst, s} = Enum.max_by(items, fn {_, s} -> s.score end)
      process = worst.data["process"] || %{}

      %{
        pid: pid,
        name: process["name"] || process["initial_call"],
        snapshots: length(items),
        score: Float.round(s.score, 1),
        feature: s.feature,
        memory: process["memory"],
        queue: process["message_queue_len"],
        rate: worst.data["rate"]
      }
    end)
    |> Enum.sort_by(&{&1.snapshots, &1.score}, :desc)
    |> Enum.take(@top)
  end

  defp median([]), do: 0.0

  defp median(values) do
    sorted = Enum.sort(values)
    Enum.at(sorted, div(length(sorted), 2))
  end
end
