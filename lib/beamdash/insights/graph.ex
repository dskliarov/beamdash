defmodule Beamdash.Insights.Graph do
  @moduledoc """
  The message graph of a seq trace, with Nx: who sends to whom, as a
  process × process matrix of message counts.

  From it: **reciprocity** (the share of messages that go both ways
  between a pair: chatty exchanges and call/reply score high, fan-out and
  chains low), **centrality** (each process's PageRank: where messages
  end up, after following them through the graph) and the **hubs**, the
  processes holding the most of it.
  """

  @damping 0.85
  @iterations 30

  @doc """
  `%{processes, reciprocity_pct, top_centrality_share_pct, hubs}` for
  seq trace `sends` (`%{from, to}`); `hubs` are the three most central
  processes as `{process, share_pct}`. `nil` without messages.
  """
  def metrics([]), do: nil

  def metrics(sends) do
    nodes = sends |> Enum.flat_map(&[&1.from, &1.to]) |> Enum.uniq()
    n = length(nodes)
    index = nodes |> Enum.with_index() |> Map.new()

    counts = Enum.frequencies_by(sends, &{index[&1.from], index[&1.to]})

    a =
      Nx.indexed_put(
        Nx.broadcast(0.0, {n, n}),
        Nx.tensor(Enum.map(Map.keys(counts), &Tuple.to_list/1)),
        Nx.tensor(Map.values(counts), type: :f32)
      )

    total = Nx.sum(a) |> Nx.to_number()
    reciprocal = a |> Nx.min(Nx.transpose(a)) |> Nx.sum() |> Nx.to_number()
    rank = page_rank(a, n) |> Nx.to_flat_list()

    hubs =
      nodes
      |> Enum.zip(rank)
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.take(3)
      |> Enum.map(fn {node, r} -> {node, Float.round(r * 100, 1)} end)

    %{
      processes: n,
      reciprocity_pct: Float.round(reciprocal * 100 / max(total, 1), 1),
      top_centrality_share_pct: hubs |> hd() |> elem(1),
      hubs: hubs
    }
  end

  # PageRank by power iteration: rows are senders, a process without
  # outgoing messages spreads its rank evenly
  defp page_rank(a, n) do
    out = Nx.sum(a, axes: [1], keep_axes: true)
    dangling = out |> Nx.equal(0) |> Nx.broadcast({n, n})
    p = Nx.select(dangling, 1 / n, Nx.divide(a, Nx.max(out, 1)))
    teleport = (1 - @damping) / n

    Enum.reduce(1..@iterations, Nx.broadcast(1 / n, {n}), fn _, r ->
      r |> Nx.dot(p) |> Nx.multiply(@damping) |> Nx.add(teleport)
    end)
  end
end
