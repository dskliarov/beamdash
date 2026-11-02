defmodule Beamdash.Logs.Filter do
  @moduledoc """
  The Logs tab filter: a text query (`word "two words" -excluded`) and a
  minimum level.
  """

  alias Beamdash.Logs.Pretty

  @term ~r/(-?)(?:"((?:[^"\\]|\\.)*)"|(\S+))/

  @doc "Parses a query into lowercased `%{include: [...], exclude: [...]}` terms."
  def parse(text) do
    terms =
      for [_, sign | groups] <- Regex.scan(@term, text),
          term = groups |> term_text() |> String.trim() |> String.downcase(),
          term not in ["", "-"] do
        {sign == "-", term}
      end

    %{
      include: for({false, t} <- terms, do: t),
      exclude: for({true, t} <- terms, do: t)
    }
  end

  @doc """
  True when every include term and no exclude term is in the entry's text.
  A `key=value` term is also in the entry when one of its fields is that pair.
  """
  def match?(%{include: include, exclude: exclude}, entry) do
    haystack = haystack(entry)
    pairs = pairs(include ++ exclude, entry)

    Enum.all?(include, &term?(&1, haystack, pairs)) and
      not Enum.any?(exclude, &term?(&1, haystack, pairs))
  end

  @doc "The filter text for a `key=value` pair, quoted when it has spaces or quotes."
  def pair_term(pair) do
    if String.contains?(pair, [" ", "\t", "\""]), do: ~s("#{escape(pair)}"), else: pair
  end

  defp escape(text), do: text |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")

  defp unescape(text), do: Regex.replace(~r/\\(.)/, text, "\\1")

  # Regex.scan leaves out trailing groups that did not match, so a bare word
  # comes back as [quoted_empty, word] and a phrase as [phrase]
  defp term_text([quoted]), do: unescape(quoted)
  defp term_text([quoted, bare]), do: if(bare == "", do: unescape(quoted), else: bare)
  defp term_text([]), do: ""

  # the entry's fields, parsed once per match and only when a term is a key=value
  defp pairs(terms, entry) do
    if Enum.any?(terms, &String.contains?(&1, "=")) do
      for {k, v} <- Pretty.all_fields(entry[:message] || ""),
          into: MapSet.new(),
          do: {String.downcase(k), String.downcase(v)}
    else
      MapSet.new()
    end
  end

  defp term?(term, haystack, pairs) do
    String.contains?(haystack, term) or field?(term, pairs)
  end

  defp field?(term, pairs) do
    case String.split(term, "=", parts: 2) do
      [key, value] when key != "" and value != "" ->
        MapSet.member?(pairs, {key, String.trim(value)})

      _ ->
        false
    end
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
