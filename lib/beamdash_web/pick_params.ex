defmodule BeamdashWeb.PickParams do
  @moduledoc """
  The function picker's state in a URL, so the Tracing and Profile tabs can
  pass their filters to each other: the module shown and its search, the
  function search, the Show filter and the picked functions.

  The Tracing tab's "traced" Show filter is "picked" in the URL.
  """

  alias BeamdashWeb.FunctionList

  @doc "The path of `page` carrying the picker `state` (`mod`, `q`, `fq`, `ff`, `picked`)."
  def path(page, state) do
    query =
      Enum.reject([mod: state.mod && Atom.to_string(state.mod), q: state.q, fq: state.fq], fn {_k,
                                                                                               v} ->
        v in [nil, ""]
      end)

    query =
      query ++ [ff: filter_name(state.ff), picked: Enum.map_join(state.picked, ",", &encode/1)]

    page <> "?" <> URI.encode_query(query)
  end

  @doc """
  The picker state in the query `params` of such a path. Modules and functions
  that are not loaded are left out.
  """
  def decode(params, modules) do
    %{
      mod: module(params["mod"], modules),
      q: params["q"] || "",
      fq: params["fq"] || "",
      ff: filter(params["ff"]),
      picked: picked(params["picked"] || "", modules)
    }
  end

  defp filter_name(:traced), do: "picked"
  defp filter_name(filter), do: Atom.to_string(filter)

  defp filter("exported"), do: :exported
  defp filter("local"), do: :local
  defp filter("picked"), do: :picked
  defp filter(_), do: :all

  defp encode({mod, :_, :_}), do: "#{mod}:_/_"
  defp encode({mod, fun, arity}), do: "#{mod}:#{fun}/#{arity}"

  defp module(nil, _modules), do: nil

  defp module(name, modules) do
    Enum.find_value(modules, fn {mod, _exports, _locals} ->
      if Atom.to_string(mod) == name, do: mod
    end)
  end

  defp picked(text, modules) do
    text
    |> String.split(",", trim: true)
    |> Enum.flat_map(&pick(&1, modules))
    |> Enum.uniq()
  end

  defp pick(text, modules) do
    case Regex.run(~r/^([^:]+):(.+)\/(\d+|_)$/, text) do
      [_, mod, "_", "_"] -> whole(mod, modules)
      [_, mod, fun, arity] -> function(mod, fun, arity, modules)
      nil -> []
    end
  end

  defp whole(mod, modules) do
    case module(mod, modules) do
      nil -> []
      mod -> [{mod, :_, :_}]
    end
  end

  defp function(mod, fun, arity, modules) do
    with mod when mod != nil <- module(mod, modules),
         {f, a} <- FunctionList.find_function(modules, mod, fun, arity) do
      [{mod, f, a}]
    else
      _ -> []
    end
  end
end
