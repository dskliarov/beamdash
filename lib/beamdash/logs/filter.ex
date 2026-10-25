defmodule Beamdash.Logs.Filter do
  @moduledoc """
  The Logs tab filter: a text query (`word "two words" -excluded`) and a
  minimum level.
  """

  @term ~r/(-?)(?:"([^"]*)"|(\S+))/

  @doc "Parses a query into lowercased `%{include: [...], exclude: [...]}` terms."
  def parse(text) do
    terms =
      for [_, sign | words] <- Regex.scan(@term, text),
          term = words |> Enum.join() |> String.trim() |> String.downcase(),
          term not in ["", "-"] do
        {sign == "-", term}
      end

    %{
      include: for({false, t} <- terms, do: t),
      exclude: for({true, t} <- terms, do: t)
    }
  end

  @doc "True when every include term and no exclude term is in the entry's text."
  def match?(%{include: include, exclude: exclude}, entry) do
    haystack = haystack(entry)

    Enum.all?(include, &String.contains?(haystack, &1)) and
      not Enum.any?(exclude, &String.contains?(haystack, &1))
  end

  defp haystack(entry) do
    meta = for {_key, value} <- entry[:meta] || [], do: value

    [entry[:message], entry[:where], entry[:pid] | meta]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> String.downcase()
  end

  @doc "True when the entry's level is at least `min_level` (`nil` accepts everything)."
  def level_ok?(nil, _entry), do: true
  def level_ok?(_min, %{level: nil}), do: false
  def level_ok?(min, %{level: level}), do: Logger.compare_levels(level, min) in [:gt, :eq]

  @doc """
  Splits `text` into `{:text, s}` and `{:mark, s}` segments, marking
  case-insensitive occurrences of the include terms (leftmost, longest first).
  """
  def highlight(text, %{include: []}), do: [{:text, text}]

  def highlight(text, %{include: include}) do
    pattern =
      include
      |> Enum.uniq()
      |> Enum.sort_by(&String.length/1, :desc)
      |> Enum.map_join("|", &Regex.escape/1)

    regex = Regex.compile!(pattern, "iu")
    ranges = regex |> Regex.scan(text, return: :index) |> Enum.map(&hd/1)

    {segments, pos} =
      Enum.reduce(ranges, {[], 0}, fn {start, len}, {acc, pos} ->
        acc = if start > pos, do: [{:text, binary_part(text, pos, start - pos)} | acc], else: acc
        {[{:mark, binary_part(text, start, len)} | acc], start + len}
      end)

    rest = binary_part(text, pos, byte_size(text) - pos)
    Enum.reverse(segments, if(rest == "", do: [], else: [{:text, rest}]))
  end
end
