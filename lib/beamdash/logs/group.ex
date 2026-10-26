defmodule Beamdash.Logs.Group do
  @moduledoc """
  Combines consecutive similar log lines. Two lines are similar when their
  level, source and message are equal once the variable parts (numbers,
  pids, ids, timestamps) are masked with `#`.

  A row is `%{id, key, count, entry, first_at, ids}`: `entry` is the newest
  line, `ids` are the entry ids newest first, and `id` is `"g-<oldest id>"`
  so it stays stable while newer lines join.
  """

  # Applied in order; each mask only sees text the previous ones left alone.
  # A function, not an attribute: compiled regexes can't be escaped into
  # code on OTP 28 with Elixir < 1.19.
  defp masks do
    [
      {~r/\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})?/, nil},
      {~r/<\d+\.\d+\.\d+>/, nil},
      {~r/#Reference<[\d.]+>/, nil},
      {~r/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/, nil},
      {~r/\b[0-9a-fA-F]{8,}\b/, ~r/\d/},
      {~r/\d+(\.\d+)?/, nil}
    ]
  end

  @doc "The grouping key `{level, where, masked_message}` of an entry."
  def key(%{level: level, where: where, message: message}) do
    masked =
      Enum.map_join(mask_spans(message), fn
        {:text, s} -> s
        {:var, _} -> "#"
      end)

    {level, where, masked}
  end

  @doc "Splits `message` into `{:text, s}` and `{:var, s}` (the masked parts) segments."
  def mask_spans(message) do
    Enum.reduce(masks(), [{:text, message}], fn mask, spans ->
      spans |> Enum.flat_map(&split_span(&1, mask)) |> merge_text()
    end)
  end

  defp split_span({:var, _} = span, _mask), do: [span]

  defp split_span({:text, text}, {regex, must_contain}) do
    # With captures included the pieces alternate text, match, text, ...
    regex
    |> Regex.split(text, include_captures: true)
    |> Enum.with_index()
    |> Enum.reject(fn {piece, _} -> piece == "" end)
    |> Enum.map(fn
      {piece, i} when rem(i, 2) == 1 ->
        if must_contain == nil or Regex.match?(must_contain, piece),
          do: {:var, piece},
          else: {:text, piece}

      {piece, _} ->
        {:text, piece}
    end)
  end

  defp merge_text(spans) do
    spans
    |> Enum.reduce([], fn
      {:text, b}, [{:text, a} | rest] -> [{:text, a <> b} | rest]
      span, acc -> [span | acc]
    end)
    |> Enum.reverse()
  end

  @doc "Groups entries (newest first) into rows (newest first)."
  def group(entries_newest_first) do
    entries_newest_first |> Enum.reverse() |> Enum.reduce([], &add(&2, &1))
  end

  @doc "Adds a newer entry on top of `rows`, joining the top row when similar."
  def add([%{key: key} = top | rest], entry) do
    case key(entry) do
      ^key -> [%{top | count: top.count + 1, entry: entry, ids: [entry.id | top.ids]} | rest]
      new_key -> [new_row(entry, new_key), top | rest]
    end
  end

  def add([], entry), do: [new_row(entry, key(entry))]

  # (the key is passed in: masking a message is the costly part)
  defp new_row(entry, key) do
    %{
      id: "g-#{entry.id}",
      key: key,
      count: 1,
      entry: entry,
      first_at: entry.at,
      ids: [entry.id]
    }
  end
end
