defmodule Beamdash.Logs.Pretty do
  @moduledoc """
  Pretty-prints the Erlang and Elixir literal terms written inside a log
  message: tuples, lists, binaries, maps, records and structs, with strings,
  atoms, numbers and the opaque references (pids, refs, funs, ports) that
  Erlang prints. The text is read as syntax only. Nothing is evaluated and
  no atom is created, so log text is safe to read. Anything that is not a
  complete literal is left as it was.
  """

  @max_bytes 65_536
  @max_candidates 64
  @max_depth 32
  @width 80

  @candidate ~r/[\{\[]|<<|\#\{|\#[a-z]\w*\{|%(?:[A-Z]\w*(?:\.[A-Z]\w*)*)?\{/
  @struct_head ~r/\A%([A-Z]\w*(?:\.[A-Z]\w*)*)\{/
  @record_head ~r/\A#([a-z]\w*)\{/
  @number ~r/\A-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?/
  @word ~r/\A[A-Za-z_][\w@]*(?:\.[A-Za-z_]\w*)*/
  @pid ~r/\A<\d+\.\d+\.\d+>/
  @opaque_ref ~r/\A#(?:Ref|Fun|PID|Port)<[^>]*>/

  @doc "Splits `text` into `{:text, string}` and `{:term, pretty}` pieces."
  def segments(text) when byte_size(text) > @max_bytes, do: [{:text, text}]

  def segments(text) do
    {pieces, cursor} =
      Enum.reduce(terms(text), {[], 0}, fn {start, node, stop}, {acc, cursor} ->
        term = {:term, render(node, column(text, start))}
        {[term, {:text, slice(text, cursor, start)} | acc], stop}
      end)

    [{:text, slice(text, cursor, byte_size(text))} | pieces]
    |> Enum.reverse()
    |> Enum.reject(&match?({:text, ""}, &1))
  end

  @doc "The `{key, value}` pairs (as printed) of the map entries and `{key, value}` tuples in `text`."
  def fields(text) do
    text
    |> terms()
    |> Enum.flat_map(fn {_start, node, _stop} -> node |> pairs([]) |> Enum.reverse() end)
    |> Enum.uniq()
  end

  @doc "True when `text` has every `{key, value}` in `filters`."
  def fields_match?([], _text), do: true

  def fields_match?(filters, text) do
    found = fields(text)
    Enum.all?(filters, &(&1 in found))
  end

  defp terms(text) do
    starts =
      @candidate
      |> Regex.scan(text, return: :index)
      |> Enum.map(fn [{start, _} | _] -> start end)
      |> Enum.take(@max_candidates)

    {found, _cursor} =
      Enum.reduce(starts, {[], 0}, fn start, {acc, cursor} ->
        if start < cursor do
          {acc, cursor}
        else
          case value(text, start, 0) do
            {:ok, node, stop} -> {[{start, node, stop} | acc], stop}
            :error -> {acc, cursor}
          end
        end
      end)

    Enum.reverse(found)
  end

  defp pairs({:tuple, [{:leaf, key}, value]}, acc), do: pairs(value, [{key, flat(value)} | acc])

  defp pairs({:map, _prefix, entries}, acc),
    do:
      Enum.reduce(entries, acc, fn {key, _sep, value}, acc ->
        pairs(value, [{flat(key), flat(value)} | acc])
      end)

  defp pairs({kind, items}, acc) when kind in [:tuple, :list],
    do: Enum.reduce(items, acc, &pairs/2)

  defp pairs(_leaf_or_binary, acc), do: acc

  defp value(_text, _i, depth) when depth > @max_depth, do: :error

  defp value(text, i, depth) do
    i = skip_ws(text, i)

    case peek(text, i) do
      ?{ -> container(text, i + 1, depth, "}", :tuple)
      ?[ -> container(text, i + 1, depth, "]", :list)
      ?< -> angle(text, i, depth)
      ?# -> hash(text, i, depth)
      ?% -> percent(text, i, depth)
      ?" -> quoted(text, i)
      ?' -> quoted(text, i)
      ?: -> colon_atom(text, i)
      c when c in ?0..?9 or c == ?- -> token(text, i, @number)
      c when c in ?A..?Z or c in ?a..?z or c == ?_ -> token(text, i, @word)
      _ -> :error
    end
  end

  defp angle(text, i, depth) do
    if peek(text, i + 1) == ?<,
      do: container(text, i + 2, depth, ">>", :bin),
      else: token(text, i, @pid)
  end

  defp hash(text, i, depth) do
    case Regex.run(@record_head, rest(text, i)) do
      [head, name] ->
        map(text, i + byte_size(head), "#" <> name, depth)

      nil ->
        if peek(text, i + 1) == ?{,
          do: map(text, i + 2, "#", depth),
          else: token(text, i, @opaque_ref)
    end
  end

  defp percent(text, i, depth) do
    case Regex.run(@struct_head, rest(text, i)) do
      [head, name] -> map(text, i + byte_size(head), "%" <> name, depth)
      nil -> if peek(text, i + 1) == ?{, do: map(text, i + 2, "%", depth), else: :error
    end
  end

  defp container(text, i, depth, close, kind) do
    with {:ok, items, stop} <- collect(text, i, close, depth, &value/3, []) do
      {:ok, {kind, items}, stop}
    end
  end

  defp map(text, i, prefix, depth) do
    with {:ok, entries, stop} <- collect(text, i, "}", depth, &entry/3, []) do
      {:ok, {:map, prefix, entries}, stop}
    end
  end

  defp entry(text, i, depth) do
    with {:ok, key, i} <- value(text, i, depth),
         i = skip_ws(text, i),
         {:ok, sep, i} <- separator(text, i, key),
         {:ok, val, i} <- value(text, i, depth) do
      {:ok, {key, sep, val}, i}
    end
  end

  defp separator(text, i, key) do
    cond do
      starts?(text, i, "=>") ->
        {:ok, "=>", i + 2}

      starts?(text, i, "=") ->
        {:ok, "=", i + 1}

      peek(text, i) == ?: and peek(text, i + 1) != ?: and match?({:leaf, _}, key) ->
        {:ok, ":", i + 1}

      true ->
        :error
    end
  end

  defp collect(text, i, close, depth, item, acc) do
    i = skip_ws(text, i)

    if starts?(text, i, close) do
      {:ok, Enum.reverse(acc), i + byte_size(close)}
    else
      with {:ok, x, i} <- item.(text, i, depth + 1) do
        i = skip_ws(text, i)

        cond do
          starts?(text, i, ",") -> collect(text, i + 1, close, depth, item, [x | acc])
          starts?(text, i, close) -> {:ok, Enum.reverse([x | acc]), i + byte_size(close)}
          true -> :error
        end
      end
    end
  end

  defp quoted(text, i) do
    case closing_quote(text, i + 1, peek(text, i)) do
      nil -> :error
      stop -> {:ok, {:leaf, slice(text, i, stop)}, stop}
    end
  end

  defp closing_quote(text, j, quote) do
    cond do
      j >= byte_size(text) -> nil
      peek(text, j) == ?\\ -> closing_quote(text, j + 2, quote)
      peek(text, j) == quote -> j + 1
      true -> closing_quote(text, j + 1, quote)
    end
  end

  defp colon_atom(text, i) do
    case peek(text, i + 1) do
      ?" ->
        with {:ok, {:leaf, s}, stop} <- quoted(text, i + 1), do: {:ok, {:leaf, ":" <> s}, stop}

      _ ->
        with {:ok, {:leaf, s}, stop} <- token(text, i + 1, @word),
             do: {:ok, {:leaf, ":" <> s}, stop}
    end
  end

  defp token(text, i, regex) do
    case Regex.run(regex, rest(text, i)) do
      [match | _] -> {:ok, {:leaf, match}, i + byte_size(match)}
      nil -> :error
    end
  end

  defp skip_ws(text, i) do
    case peek(text, i) do
      c when c in [?\s, ?\t, ?\n, ?\r] -> skip_ws(text, i + 1)
      _ -> i
    end
  end

  defp render(node, col) do
    flat = flat(node)

    if col + String.length(flat) <= @width or unbreakable?(node),
      do: flat,
      else: broken(node, col)
  end

  defp unbreakable?({:leaf, _}), do: true
  defp unbreakable?({_, []}), do: true
  defp unbreakable?({:map, _, []}), do: true
  defp unbreakable?(_), do: false

  defp flat({:leaf, text}), do: text
  defp flat({:tuple, items}), do: "{" <> join(items) <> "}"
  defp flat({:list, items}), do: "[" <> join(items) <> "]"
  defp flat({:bin, items}), do: "<<" <> join(items) <> ">>"

  defp flat({:map, prefix, entries}) do
    body = Enum.map_join(entries, ", ", fn {k, sep, v} -> entry_key(k, sep) <> flat(v) end)
    prefix <> "{" <> body <> "}"
  end

  defp join(items), do: Enum.map_join(items, ", ", &flat/1)

  defp broken({:tuple, items}, col), do: block("{", "}", Enum.map(items, &{"", &1}), col)
  defp broken({:list, items}, col), do: block("[", "]", Enum.map(items, &{"", &1}), col)
  defp broken({:bin, items}, col), do: block("<<", ">>", Enum.map(items, &{"", &1}), col)

  defp broken({:map, prefix, entries}, col) do
    children = Enum.map(entries, fn {k, sep, v} -> {entry_key(k, sep), v} end)
    block(prefix <> "{", "}", children, col)
  end

  defp block(open, close, children, col) do
    pad = String.duplicate(" ", col + 2)

    lines =
      for {prefix, node} <- children,
          do: pad <> prefix <> render(node, col + 2 + String.length(prefix))

    open <> "\n" <> Enum.join(lines, ",\n") <> "\n" <> String.duplicate(" ", col) <> close
  end

  defp entry_key(key, "=>"), do: flat(key) <> " => "
  defp entry_key(key, "="), do: flat(key) <> " = "
  defp entry_key(key, ":"), do: flat(key) <> ": "

  defp column(text, start) do
    text |> binary_part(0, start) |> String.split("\n") |> List.last() |> String.length()
  end

  defp slice(text, from, to), do: binary_part(text, from, to - from)
  defp rest(text, i), do: binary_part(text, i, byte_size(text) - i)
  defp starts?(text, i, prefix), do: String.starts_with?(rest(text, i), prefix)

  defp peek(text, i) when i < byte_size(text), do: :binary.at(text, i)
  defp peek(_text, _i), do: nil
end
