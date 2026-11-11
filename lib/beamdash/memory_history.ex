defmodule Beamdash.MemoryHistory do
  @moduledoc """
  What changed between consecutive stored `:memory` samples, for the Memory
  page's History view. Input rows are `Beamdash.Store` rows of kind `:memory`,
  oldest first, as `Beamdash.Sampler` wrote them.
  """

  @top_growth 3

  @doc """
  One map per sample, oldest first: its total memory and what changed since
  the sample before it (`nil` for the first). `growing` lists up to three
  tables whose memory rose, as `{name, bytes}`, largest first. Only tables
  present in both samples are compared, since the sampler keeps just the
  largest ones.
  """
  def changes(rows) do
    {changes, _previous} =
      Enum.map_reduce(rows, nil, fn row, previous ->
        sample = sample(row)
        {change(sample, previous), sample}
      end)

    changes
  end

  @doc "Totals across the samples of `changes/1`, or `nil` when there are none."
  def summary([]), do: nil

  def summary(changes) do
    memories = Enum.map(changes, & &1.memory)

    %{
      samples: length(changes),
      from: hd(memories),
      to: List.last(memories),
      peak: Enum.max(memories)
    }
  end

  defp sample(row) do
    %{
      at: row.at,
      memory: get_in(row.data, ["memory", "total"]),
      atoms: row.data["atom_count"],
      ets: row.data["ets_count"],
      tables:
        for(table <- row.data["tables"] || [], table["name"], into: %{}) do
          {table["name"], table["memory"]}
        end
    }
  end

  defp change(sample, nil) do
    %{
      at: sample.at,
      memory: sample.memory,
      atoms: sample.atoms,
      ets: sample.ets,
      memory_delta: nil,
      atoms_delta: nil,
      ets_delta: nil,
      growing: []
    }
  end

  defp change(sample, previous) do
    %{
      at: sample.at,
      memory: sample.memory,
      atoms: sample.atoms,
      ets: sample.ets,
      memory_delta: sample.memory - previous.memory,
      atoms_delta: sample.atoms - previous.atoms,
      ets_delta: sample.ets - previous.ets,
      growing: growing(sample.tables, previous.tables)
    }
  end

  defp growing(tables, previous) do
    tables
    |> Enum.flat_map(fn {name, bytes} ->
      case previous do
        %{^name => old} when bytes > old -> [{name, bytes - old}]
        _ -> []
      end
    end)
    |> Enum.sort_by(fn {_name, grew} -> grew end, :desc)
    |> Enum.take(@top_growth)
  end
end
