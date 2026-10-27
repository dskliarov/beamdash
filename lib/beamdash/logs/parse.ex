defmodule Beamdash.Logs.Parse do
  @moduledoc """
  Turns one `kubectl logs --timestamps` line into a log entry (without `:id`).

  A leading RFC 3339 timestamp becomes `at`. The rest (ANSI colour codes
  removed) is read as:

    * a JSON log object (`level`/`severity`/`lvl`/`log.level`, `msg`/`message`);
    * an Elixir `Logger` line: `12:04:01.233 [info] msg`, optionally with a
      date (`$date $time`) and Phoenix's metadata
      (`12:04:01.233 request_id=F1 [info] msg`, the pairs become `meta`);
    * logfmt (`level=info msg="..." key=value`);
    * a line starting with an upper-case level word (`INFO ...`, `ERROR: ...`);

  or else plain text with no level.
  """

  @timestamp ~r/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})) /
  @ansi ~r/\e\[[0-9;]*m/
  # `[$date ]$time $metadata[$level] $message`: Phoenix's default puts
  # metadata (space-separated `key=value` pairs) between the time and the
  # level. A key has no `=`, so a pair splits only one way (no backtracking
  # blowup on a long line of `a=b=c` tokens that turns out not to match).
  @logger_line ~r/^(?:(?:\d{4}-\d{2}-\d{2}[ T])?\d{2}:\d{2}:\d{2}(?:\.\d+)? )?((?:[^\s=]+=\S+ )*)\[(\w+)\] ?(.*)$/s
  # logfmt: `key=value` or `key="quoted value"` pairs
  @logfmt_pair ~r/([^\s=]+)=("(?:[^"\\]|\\.)*"|\S*)/
  # an upper-case level word first, then a space or `:` (`INFO ...`, `ERROR: ...`)
  @level_first ~r/^([A-Z]+):? (.*)$/s

  @levels Map.new(
            [:emergency, :alert, :critical, :error, :warning, :notice, :info, :debug],
            &{Atom.to_string(&1), &1}
          )
          |> Map.merge(%{"warn" => :warning, "err" => :error})

  @doc "Parses `text` into `%{at, level, pid, where, message, meta, raw}`."
  def line(text) do
    {at, rest} = split_timestamp(text)
    rest = String.replace(rest, @ansi, "")

    base = %{at: at, level: nil, pid: nil, where: nil, message: rest, meta: [], raw: text}
    Map.merge(base, parse_body(rest))
  end

  @doc "True for a stack-trace or multi-line continuation (indented after the timestamp)."
  def continuation?(text) do
    {_at, rest} = split_timestamp(text)
    String.starts_with?(rest, [" ", "\t"])
  end

  @doc """
  True when nothing but whitespace follows the timestamp. Elixir's default
  console format starts every event with a newline, so such lines carry
  nothing; they are neither entries nor continuations.
  """
  def blank?(text) do
    {_at, rest} = split_timestamp(text)
    String.trim(rest) == ""
  end

  defp split_timestamp(text) do
    case Regex.run(@timestamp, text) do
      [full, stamp] ->
        {parse_datetime(stamp),
         binary_part(text, byte_size(full), byte_size(text) - byte_size(full))}

      nil ->
        {nil, text}
    end
  end

  defp parse_datetime(stamp) do
    case DateTime.from_iso8601(stamp) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :microsecond)
      _ -> nil
    end
  end

  defp parse_body("{" <> _ = rest) do
    case Jason.decode(rest) do
      {:ok, %{} = json} -> from_json(json, rest)
      _ -> parse_logger_line(rest)
    end
  end

  defp parse_body(rest), do: parse_logger_line(rest)

  # Each format in turn; the first that yields a known level wins.
  defp parse_logger_line(rest) do
    with nil <- logger_line(rest),
         nil <- logfmt(rest),
         nil <- level_first(rest) do
      %{}
    end
  end

  defp logger_line(rest) do
    with [_, pairs, level, message] <- Regex.run(@logger_line, rest),
         level when level != nil <- level_atom(level) do
      %{level: level, message: message, meta: logger_meta(pairs)}
    else
      _ -> nil
    end
  end

  defp logfmt(rest) do
    pairs =
      for [_, key, value] <- Regex.scan(@logfmt_pair, rest),
          do: {key, unquote_value(value)}

    with {_, level} <- List.keyfind(pairs, "level", 0),
         level when level != nil <- level_atom(level) do
      message =
        case List.keyfind(pairs, "msg", 0) || List.keyfind(pairs, "message", 0) do
          {_, msg} -> msg
          nil -> rest
        end

      meta = Enum.reject(pairs, fn {k, _} -> k in ["level", "msg", "message"] end)
      %{level: level, message: message, meta: meta}
    else
      _ -> nil
    end
  end

  defp unquote_value(~s(") <> _ = quoted) do
    case Jason.decode(quoted) do
      {:ok, value} when is_binary(value) -> value
      _ -> quoted
    end
  end

  defp unquote_value(value), do: value

  defp level_first(rest) do
    with [_, word, message] <- Regex.run(@level_first, rest),
         true <- word == String.upcase(word),
         level when level != nil <- level_atom(word) do
      %{level: level, message: message}
    else
      _ -> nil
    end
  end

  defp logger_meta(pairs) do
    for pair <- String.split(pairs, " ", trim: true) do
      [key, value] = String.split(pair, "=", parts: 2)
      {key, value}
    end
  end

  defp from_json(json, rest) do
    {level, json} = take(json, ["level", "severity", "lvl", "log.level"])
    {message, json} = take(json, ["msg", "message"])
    {where, json} = take(json, ["module", "logger"])
    {pid, json} = take(json, ["pid"])

    %{
      level: level_atom(level),
      message: if(message, do: to_text(message), else: rest),
      where: string_or_nil(where),
      pid: string_or_nil(pid),
      meta: json |> Enum.sort() |> Enum.map(fn {k, v} -> {k, to_text(v)} end)
    }
  end

  # Value of the first present key, and the map without that key.
  defp take(json, keys) do
    case Enum.find(keys, &Map.has_key?(json, &1)) do
      nil -> {nil, json}
      key -> Map.pop(json, key)
    end
  end

  # `"module": false` and the like are not a place or a pid
  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_), do: nil

  defp to_text(value) when is_binary(value), do: value
  defp to_text(value), do: Jason.encode!(value)

  defp level_atom(level) when is_binary(level) do
    Map.get(@levels, String.downcase(level))
  end

  defp level_atom(_), do: nil
end
