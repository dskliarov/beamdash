defmodule Beamdash.Insights.Groups do
  @moduledoc """
  Groups the node's processes by how they behave, with k-means
  (`Scholar.Cluster.KMeans`): a node of thousands of processes reads as a
  handful of groups ("idle gen_servers", "busy workers with a queue"…).

  Each process is a point of standardized features: memory, queue and
  reductions rate (log scale), whether it is running, and its OTP kind.
  Each group is described by its size, typical values, most common kind
  and initial call, and its biggest members.
  """
  alias Beamdash.Insights.Series

  @max_points 1_500
  @kinds [:gen_server, :gen_statem, :gen_event, :supervisor]

  @doc """
  `{:ok, [group]}` for `procs` (`Beamdash.Target.processes/0`) with
  reductions `rates`, in `k` groups (fewer when there are few processes),
  biggest group first. A group is `%{size, share_pct, memory, queue, rate,
  kind, initial_call, running_pct, members}`; typical values are medians
  and `members` the #{5} largest by memory.
  """
  def group(procs, rates, k \\ 5, opts \\ []) do
    procs = procs |> Enum.sort_by(& &1.memory, :desc) |> Enum.take(@max_points)
    k = min(k, length(procs))

    if k < 2 do
      {:error, "Too few processes to group."}
    else
      x = procs |> Enum.map(&features(&1, rates)) |> Nx.tensor(type: :f32) |> standardize()

      model =
        Scholar.Cluster.KMeans.fit(x,
          num_clusters: k,
          num_runs: Keyword.get(opts, :num_runs, 3),
          max_iterations: 50,
          key: Nx.Random.key(Keyword.get(opts, :seed, 42))
        )

      labels = Nx.to_flat_list(model.labels)
      total = length(procs)

      groups =
        procs
        |> Enum.zip(labels)
        |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
        |> Enum.map(fn {_label, members} -> describe(members, rates, total) end)
        |> Enum.sort_by(& &1.size, :desc)

      {:ok, groups}
    end
  end

  @doc false
  def features(p, rates) do
    running = if p.status in [:running, :runnable], do: 1.0, else: 0.0

    [
      Series.slog(p.memory),
      Series.slog(p.message_queue_len || 0),
      Series.slog(rates[p.pid] || 0),
      running
      | Enum.map(@kinds, &if(p[:kind] == &1, do: 1.0, else: 0.0))
    ]
  end

  # columns to mean 0 and sd 1, so no feature dominates the distances
  defp standardize(x) do
    mean = Nx.mean(x, axes: [0])
    sd = x |> Nx.standard_deviation(axes: [0]) |> Nx.max(1.0e-6)
    x |> Nx.subtract(mean) |> Nx.divide(sd)
  end

  defp describe(members, rates, total) do
    median = fn values ->
      values = values |> Enum.map(&(&1 || 0)) |> Enum.sort()
      Enum.at(values, div(length(values), 2))
    end

    %{
      size: length(members),
      share_pct: Float.round(length(members) * 100 / total, 1),
      memory: median.(Enum.map(members, & &1.memory)),
      queue: median.(Enum.map(members, & &1.message_queue_len)),
      rate: median.(Enum.map(members, &rates[&1.pid])),
      running_pct:
        Float.round(
          Enum.count(members, &(&1.status in [:running, :runnable])) * 100 / length(members),
          0
        ),
      kind: most_common(members, & &1[:kind]),
      initial_call: most_common(members, & &1[:initial_call]),
      members: members |> Enum.sort_by(& &1.memory, :desc) |> Enum.take(5)
    }
  end

  # the most common value and its share, or nil when none is set
  defp most_common(members, f) do
    case members |> Enum.map(f) |> Enum.reject(&is_nil/1) |> Enum.frequencies() do
      empty when empty == %{} ->
        nil

      freq ->
        {value, n} = Enum.max_by(freq, &elem(&1, 1))
        {value, round(n * 100 / length(members))}
    end
  end
end
