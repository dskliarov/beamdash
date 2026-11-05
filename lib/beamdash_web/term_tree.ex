defmodule BeamdashWeb.TermTree do
  @moduledoc """
  A term as nested, collapsible `<details>` blocks. Tuples, lists and maps open
  into their elements, and the first `expand` levels start open. A container
  shows its first elements and a count of the rest, and a whole tree stops at a
  node budget, so a huge value cannot flood the page.
  """
  use Phoenix.Component

  alias Beamdash.Format

  @fits 80
  @max_items 100
  @max_nodes 2_000

  attr :value, :any, required: true
  attr :syntax, :atom, default: :erlang
  attr :expand, :integer, default: 2, doc: "levels that start expanded"
  attr :max_nodes, :integer, default: @max_nodes, doc: "node budget for the whole tree"

  def tree(assigns) do
    ~H"""
    <.tree_node node={build(@value, @syntax, @max_nodes)} expand={@expand} depth={0} />
    """
  end

  attr :node, :any, required: true
  attr :expand, :integer, required: true
  attr :depth, :integer, required: true

  defp tree_node(assigns) do
    ~H"""
    <%= case @node do %>
      <% {:leaf, text} -> %>
        <span class="term-leaf mono">{text}</span>
      <% :cut -> %>
        <span class="muted small">…</span>
      <% {:group, open, close, count, children, hidden} -> %>
        <details class="term-group" open={@depth < @expand}>
          <summary class="mono">
            {open}…{close} <span class="muted small">{Format.number(count)} items</span>
          </summary>
          <ul class="term-items">
            <li :for={{key, child} <- children}>
              <span :if={key} class="mono">{key} =></span>
              <.tree_node node={child} expand={@expand} depth={@depth + 1} />
            </li>
          </ul>
          <span :if={hidden > 0} class="muted small">… {Format.number(hidden)} more</span>
        </details>
    <% end %>
    """
  end

  @doc false
  def build(value, syntax, max_nodes \\ @max_nodes) do
    {node, _budget} = build_node(value, syntax, max_nodes)
    node
  end

  defp build_node(_value, _syntax, budget) when budget <= 0, do: {:cut, budget}

  defp build_node(value, syntax, budget) do
    text = Format.term(value, syntax, 200)
    fits = String.length(text) <= @fits and not String.contains?(text, "...")

    case {container(value, syntax), fits} do
      {nil, _fits} ->
        {{:leaf, text}, budget - 1}

      {_container, true} ->
        {{:leaf, text}, budget - 1}

      {{open, close, count, entries}, false} ->
        {children, budget} =
          entries
          |> Enum.take(@max_items)
          |> Enum.map_reduce(budget - 1, fn {key, child}, acc ->
            {node, acc} = build_node(child, syntax, acc)
            {{key, node}, acc}
          end)

        hidden = count - length(children)
        {{:group, open, close, count, merge_scalars(children), hidden}, budget}
    end
  end

  defp merge_scalars(children) do
    children
    |> Enum.chunk_by(&scalar?/1)
    |> Enum.flat_map(fn run ->
      if scalar?(hd(run)),
        do: [{nil, {:leaf, Enum.map_join(run, ", ", fn {nil, {:leaf, text}} -> text end)}}],
        else: run
    end)
  end

  defp scalar?({nil, {:leaf, text}}), do: String.length(text) <= 20
  defp scalar?(_child), do: false

  defp container(value, _syntax) when is_tuple(value) and tuple_size(value) > 0 do
    {"{", "}", tuple_size(value), Stream.map(Tuple.to_list(value), &{nil, &1})}
  end

  defp container(value, syntax) when is_map(value) and map_size(value) > 0 do
    open = if syntax == :elixir, do: "%{", else: "\#{"

    {open, "}", map_size(value),
     Stream.map(value, fn {k, v} -> {Format.term(k, syntax, 80), v} end)}
  end

  defp container(value, _syntax) when is_list(value) and value != [] do
    if proper?(value) and not :io_lib.printable_list(value),
      do: {"[", "]", length(value), Stream.map(value, &{nil, &1})}
  end

  defp container(_value, _syntax), do: nil

  defp proper?([]), do: true
  defp proper?([_ | rest]), do: proper?(rest)
  defp proper?(_), do: false
end
