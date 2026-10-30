defmodule Beamdash.Insights.Graph do
  @moduledoc """
  The message graph of a seq trace: who sends to whom, as sparse edges
  with message counts. Memory is proportional to processes and edges.

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
    counts = Enum.frequencies_by(sends, &{&1.from, &1.to})
    total = length(sends)

    reciprocal =
      Enum.reduce(counts, 0, fn {{from, to}, count}, acc ->
        acc + min(count, Map.get(counts, {to, from}, 0))
      end)

    rank = page_rank(nodes, counts, n)

    hubs =
      nodes
      |> Enum.map(&{&1, Map.fetch!(rank, &1)})
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

  # A dangling node distributes its rank to every node. Accumulate its
  # share once, then distribute the other shares only along existing edges.
  defp page_rank(nodes, counts, n) do
    out =
      Enum.reduce(counts, %{}, fn {{from, _}, count}, acc ->
        Map.update(acc, from, count, &(&1 + count))
      end)

    initial = Map.new(nodes, &{&1, 1 / n})

    Enum.reduce(1..@iterations, initial, fn _, rank ->
      dangling =
        Enum.reduce(nodes, 0.0, fn node, sum ->
          if Map.has_key?(out, node), do: sum, else: sum + rank[node]
        end)

      base = (1 - @damping) / n + @damping * dangling / n
      next = Map.new(nodes, &{&1, base})

      Enum.reduce(counts, next, fn {{from, to}, count}, acc ->
        share = @damping * rank[from] * count / out[from]
        Map.update!(acc, to, &(&1 + share))
      end)
    end)
  end
end
