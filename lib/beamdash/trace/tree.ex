defmodule Beamdash.Trace.Tree do
  @moduledoc """
  The trace log arranged by what each call ran: module, then function with
  arity, then how the calls ended (`ok`, `error` or `no_return`), then the
  calls themselves. A node counts its calls, how many returned (`ok`), how
  many raised (`errors`), how many have not returned yet (`running`), and the
  total time of its finished calls. A node's `scope` is what the trace log
  filters on: `{:module, mod}`, `{:function, mod, fun, arity}`,
  `{:result, mod, fun, arity, outcome}` or `{:call, id}`.
  """

  @totals [:calls, :ok, :errors, :running, :duration_us]

  @doc "The tree of `entries`: `%{nodes, calls}`. Nodes with the most errors come first, then the most calls."
  def build(entries) do
    modules =
      entries
      |> Enum.group_by(& &1.mod)
      |> Enum.map(fn {mod, calls} -> module_node(mod, calls) end)
      |> sort()

    %{nodes: modules, calls: length(entries)}
  end

  @doc "True when `entry` is a call in the part of the tree `scope` names."
  def in_scope?({:module, mod}, entry), do: entry.mod == mod

  def in_scope?({:function, mod, fun, arity}, entry),
    do: entry.mod == mod and entry.fun == fun and entry.arity == arity

  def in_scope?({:result, mod, fun, arity, outcome}, entry),
    do: in_scope?({:function, mod, fun, arity}, entry) and outcome(entry) == outcome

  def in_scope?({:call, id}, entry), do: entry.id == id

  @doc "The nodes to show, depth first: `%{node, depth, open?}`, children only under open nodes."
  def rows(nodes, open, depth \\ 0) do
    Enum.flat_map(nodes, fn node ->
      open? = node.children != [] and MapSet.member?(open, node.id)
      row = %{node: node, depth: depth, open?: open?}
      if open?, do: [row | rows(node.children, open, depth + 1)], else: [row]
    end)
  end

  @doc "The node with `id`, or nil."
  def find(nodes, id) do
    Enum.find_value(nodes, fn node ->
      if node.id == id, do: node, else: find(node.children, id)
    end)
  end

  @doc "How a call ended: `:ok`, `:error`, or `:no_return` while it has not returned."
  def outcome(%{result: {:return, _}}), do: :ok
  def outcome(%{result: {:exception, _}}), do: :error
  def outcome(_), do: :no_return

  defp module_node(mod, calls) do
    functions =
      calls
      |> Enum.group_by(&{&1.fun, &1.arity})
      |> Enum.map(fn {{fun, arity}, fcalls} -> function_node(mod, fun, arity, fcalls) end)

    node(:module, %{id: "m:#{mod}", scope: {:module, mod}, mod: mod}, sum(functions), functions)
  end

  defp function_node(mod, fun, arity, calls) do
    results =
      calls
      |> Enum.group_by(&outcome/1)
      |> Enum.map(fn {outcome, rcalls} -> result_node(mod, fun, arity, outcome, rcalls) end)

    fields = %{
      id: "f:#{mod}:#{fun}/#{arity}",
      scope: {:function, mod, fun, arity},
      mod: mod,
      fun: fun,
      arity: arity
    }

    node(:function, fields, sum(results), results)
  end

  defp result_node(mod, fun, arity, outcome, calls) do
    fields = %{
      id: "r:#{mod}:#{fun}/#{arity}:#{outcome}",
      scope: {:result, mod, fun, arity, outcome},
      mod: mod,
      fun: fun,
      arity: arity,
      outcome: outcome
    }

    leaves = Enum.map(calls, &call_node/1)
    node(:result, fields, sum(leaves), leaves)
  end

  defp call_node(entry) do
    fields = %{
      id: "c:#{entry.id}",
      scope: {:call, entry.id},
      mod: entry.mod,
      fun: entry.fun,
      arity: entry.arity,
      outcome: outcome(entry),
      at: entry.call_us
    }

    node(:call, fields, stats(entry), [])
  end

  defp node(kind, fields, totals, children) do
    %{kind: kind, mod: nil, fun: nil, arity: nil, outcome: nil, at: nil}
    |> Map.merge(fields)
    |> Map.put(:kind, kind)
    |> Map.merge(Map.take(totals, @totals))
    |> Map.put(:children, sort(children))
  end

  defp stats(entry) do
    {ok, errors, running} =
      case outcome(entry) do
        :ok -> {1, 0, 0}
        :error -> {0, 1, 0}
        :no_return -> {0, 0, 1}
      end

    %{calls: 1, ok: ok, errors: errors, running: running, duration_us: duration(entry)}
  end

  defp duration(%{call_us: c, return_us: r}) when is_integer(c) and is_integer(r), do: r - c
  defp duration(_), do: 0

  defp add(a, b), do: Map.merge(a, b, fn _, x, y -> x + y end)

  defp sum(nodes), do: nodes |> Enum.map(&Map.take(&1, @totals)) |> Enum.reduce(&add/2)

  defp sort(nodes), do: Enum.sort_by(nodes, &sort_key/1)

  # calls are listed newest first; the other levels by errors, then calls, then name
  defp sort_key(%{kind: :call, at: at}), do: -(at || 0)

  defp sort_key(node),
    do:
      {-node.errors, -node.calls, to_string(node.mod), to_string(node.fun), node.arity || 0,
       to_string(node.outcome)}
end
