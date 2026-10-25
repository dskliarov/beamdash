defmodule Beamdash.Record do
  @moduledoc """
  An Erlang record recovered by erlyberly.

  erlyberly's agent rewrites gen_server state it can match to a record
  definition as `{erlyberly_record, Name, [{erlyberly_record_field, K, V}]}`.
  `decode/1` turns those into this struct so they print as `#name{k: v}`.
  """

  defstruct [:name, fields: []]

  @doc "Recursively replaces erlyberly record tuples with `%Beamdash.Record{}`."
  def decode({:erlyberly_record, name, fields}) when is_atom(name) and is_list(fields) do
    %__MODULE__{
      name: name,
      fields: for({:erlyberly_record_field, k, v} <- fields, do: {k, decode(v)})
    }
  end

  def decode(list) when is_list(list) do
    if proper_list?(list), do: Enum.map(list, &decode/1), else: list
  end

  def decode(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&decode/1) |> List.to_tuple()

  def decode(%_{} = struct), do: struct
  def decode(map) when is_map(map), do: Map.new(map, fn {k, v} -> {decode(k), decode(v)} end)
  def decode(other), do: other

  @doc """
  Names records in a plain term: every tuple whose first element is the
  name of one of `defs` (`[{name, [field]}]`, as erlyberly's
  `load_module_records/1` returns them) and whose size fits becomes a
  `%Beamdash.Record{}`, recursively.
  """
  def name_records(term, []), do: term

  def name_records(term, defs) do
    index = Map.new(defs, fn {name, fields} -> {{name, length(fields) + 1}, fields} end)
    named(term, index)
  end

  defp named(tuple, index) when is_tuple(tuple) and tuple_size(tuple) > 0 do
    case Map.fetch(index, {elem(tuple, 0), tuple_size(tuple)}) do
      {:ok, fields} ->
        [tag | values] = Tuple.to_list(tuple)
        %__MODULE__{name: tag, fields: Enum.zip(fields, Enum.map(values, &named(&1, index)))}

      :error ->
        tuple |> Tuple.to_list() |> Enum.map(&named(&1, index)) |> List.to_tuple()
    end
  end

  defp named(list, index) when is_list(list) do
    if proper_list?(list), do: Enum.map(list, &named(&1, index)), else: list
  end

  defp named(%_{} = struct, _index), do: struct

  defp named(map, index) when is_map(map),
    do: Map.new(map, fn {k, v} -> {named(k, index), named(v, index)} end)

  defp named(other, _index), do: other

  @doc """
  The reverse of `decode/1` for Erlang-syntax printing: turns
  `%Beamdash.Record{}` back into plain record tuples and returns the field
  names seen, as `%{{name, field_count} => [field]}`, for io_lib_pretty's
  `record_print_fun`.
  """
  def to_erlang(term), do: to_erlang(term, %{})

  defp to_erlang(%__MODULE__{name: name, fields: fields}, defs) do
    {values, defs} = Enum.map_reduce(fields, defs, fn {_k, v}, acc -> to_erlang(v, acc) end)
    defs = Map.put(defs, {name, length(fields)}, Enum.map(fields, &elem(&1, 0)))
    {List.to_tuple([name | values]), defs}
  end

  defp to_erlang(list, defs) when is_list(list) do
    if proper_list?(list), do: Enum.map_reduce(list, defs, &to_erlang/2), else: {list, defs}
  end

  defp to_erlang(tuple, defs) when is_tuple(tuple) do
    {items, defs} = tuple |> Tuple.to_list() |> Enum.map_reduce(defs, &to_erlang/2)
    {List.to_tuple(items), defs}
  end

  defp to_erlang(%_{} = struct, defs), do: {struct, defs}

  defp to_erlang(map, defs) when is_map(map) do
    {pairs, defs} =
      Enum.map_reduce(map, defs, fn {k, v}, acc ->
        {k, acc} = to_erlang(k, acc)
        {v, acc} = to_erlang(v, acc)
        {{k, v}, acc}
      end)

    {Map.new(pairs), defs}
  end

  defp to_erlang(other, defs), do: {other, defs}

  defp proper_list?([]), do: true
  defp proper_list?([_ | tail]), do: proper_list?(tail)
  defp proper_list?(_), do: false
end

defimpl Inspect, for: Beamdash.Record do
  import Inspect.Algebra

  def inspect(%{name: name, fields: fields}, opts) do
    field = fn {k, v}, opts -> concat([Atom.to_string(k), ": ", to_doc(v, opts)]) end
    container_doc("##{name}{", fields, "}", opts, field, separator: ",", break: :maybe)
  end
end
