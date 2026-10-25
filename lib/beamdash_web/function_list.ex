defmodule BeamdashWeb.FunctionList do
  @moduledoc """
  Browsing the target's loaded modules and their functions, shared by the
  Tracing and Profile tabs: module filtering, a module's functions
  (exported first, compiler-generated ones hidden), function search
  (`name` or `name/arity`) and the search highlight.

  `modules` is `Beamdash.Tracer.module_functions/0`'s
  `[{mod, exports, locals}]`.
  """
  use Phoenix.Component

  alias Beamdash.Format

  @max_modules 150

  @doc "Modules whose name contains `filter`, sorted, at most #{@max_modules}."
  def matching_modules(modules, filter, syntax) do
    needle = needle(filter)

    modules
    |> Enum.map(&elem(&1, 0))
    |> Enum.filter(fn mod ->
      needle == "" or String.contains?(String.downcase(Format.name(mod, syntax)), needle)
    end)
    |> Enum.sort_by(&Format.name(&1, syntax))
    |> Enum.take(@max_modules)
  end

  @doc """
  `[{fun, arity, exported?}]` of `mod`: exported first, then local;
  funs, `module_info` and `__info__` are hidden.
  """
  def functions_of(_modules, nil), do: []

  def functions_of(modules, mod) do
    case List.keyfind(modules, mod, 0) do
      {^mod, exports, locals} ->
        visible = fn {f, _a} ->
          name = Atom.to_string(f)
          not String.starts_with?(name, "-") and f != :module_info and f != :__info__
        end

        for({f, a} = fa <- Enum.sort(exports), visible.(fa), do: {f, a, true}) ++
          for({f, a} = fa <- Enum.sort(locals), visible.(fa), do: {f, a, false})

      nil ->
        []
    end
  end

  def needle(query), do: query |> String.trim() |> String.downcase()

  @doc ~s|"name" matches anywhere in the name; "name/arity" (or "name/") also checks the arity.|
  def matches?(_fun, "", _syntax), do: true

  def matches?({f, a, _}, needle, syntax) do
    name = String.downcase(fn_name(f, syntax))

    case String.split(needle, "/", parts: 2) do
      [n] -> String.contains?(name, n)
      [n, ""] -> String.contains?(name, n)
      [n, arity] -> String.contains?(name, n) and Integer.to_string(a) == arity
    end
  end

  @doc "A function name as the syntax writes it ('quoted' in Erlang when needed)."
  def fn_name(fun, :erlang), do: fun |> :io_lib.write_atom() |> IO.chardata_to_string()
  def fn_name(fun, :elixir), do: Atom.to_string(fun)

  attr :text, :string, required: true
  attr :needle, :string, required: true

  @doc "The text with the part matching the search marked."
  def highlight(assigns) do
    assigns = assign(assigns, parts: split_match(assigns.text, assigns.needle))

    # one element per part, so no whitespace ends up between them
    ~H"""
    <span :for={{kind, part} <- @parts} class={kind == :match && "hit"}>{part}</span>
    """
  end

  defp split_match(text, ""), do: [{:text, text}]

  defp split_match(text, needle) do
    # match on the name only (an arity in the search is matched separately)
    name_needle = needle |> String.split("/") |> hd()

    case name_needle != "" && :binary.match(String.downcase(text), name_needle) do
      {start, len} ->
        <<pre::binary-size(^start), hit::binary-size(^len), post::binary>> = text
        Enum.reject([{:text, pre}, {:match, hit}, {:text, post}], &(elem(&1, 1) == ""))

      _ ->
        [{:text, text}]
    end
  end
end
