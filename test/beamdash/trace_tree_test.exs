defmodule Beamdash.Trace.TreeTest do
  use ExUnit.Case, async: true

  alias Beamdash.Trace.Tree

  defp entry(id, mod, fun, arity, result, call_us \\ 0, return_us \\ nil),
    do: %{
      id: id,
      mod: mod,
      fun: fun,
      arity: arity,
      result: result,
      call_us: call_us,
      return_us: return_us
    }

  defp entries do
    [
      entry(1, :alpha, :bar, 1, {:return, 1}, 0, 10),
      entry(2, :alpha, :bar, 1, {:exception, {:error, :boom}}, 0, 30),
      entry(3, :alpha, :baz, 0, :pending, 5, nil),
      entry(4, :beta, :qux, 2, {:return, :ok}, 0, 4)
    ]
  end

  defp summary(node), do: {node.id, node.calls, node.ok, node.errors, node.running}

  test "groups calls under their module and counts outcomes" do
    %{nodes: [alpha, beta], calls: 4} = Tree.build(entries())

    assert summary(alpha) == {"m:alpha", 3, 1, 1, 1}
    assert alpha.duration_us == 40
    assert summary(beta) == {"m:beta", 1, 1, 0, 0}
  end

  test "lists the functions of a module with errors first" do
    %{nodes: [alpha, _beta]} = Tree.build(entries())

    assert [bar, baz] = alpha.children
    assert summary(bar) == {"f:alpha:bar/1", 2, 1, 1, 0}
    assert summary(baz) == {"f:alpha:baz/0", 1, 0, 0, 1}
  end

  test "splits a function into its results, errors first, then each call" do
    %{nodes: [alpha, _beta]} = Tree.build(entries())
    [bar | _] = alpha.children

    assert [error, ok] = bar.children
    assert {error.id, error.outcome, error.calls} == {"r:alpha:bar/1:error", :error, 1}
    assert {ok.id, ok.outcome, ok.calls} == {"r:alpha:bar/1:ok", :ok, 1}

    assert [call] = error.children
    assert {call.id, call.outcome, call.at} == {"c:2", :error, 0}
  end

  test "a function's duration is the time of its finished calls" do
    %{nodes: [alpha, _beta]} = Tree.build(entries())
    [bar | _] = alpha.children

    assert bar.duration_us == 40
    assert hd(bar.children).duration_us == 30
  end

  test "lists calls newest first" do
    newest = [
      entry(5, :alpha, :baz, 0, {:return, 1}, 7, 8),
      entry(6, :alpha, :baz, 0, {:return, 1}, 9, 10)
    ]

    %{nodes: [alpha]} = Tree.build(newest)
    [baz] = alpha.children
    [ok] = baz.children

    assert Enum.map(ok.children, & &1.id) == ["c:6", "c:5"]
  end

  test "gives each node the scope the log filters on" do
    %{nodes: [alpha, _beta]} = Tree.build(entries())
    [bar | _] = alpha.children
    [error, _ok] = bar.children
    [call] = error.children

    assert alpha.scope == {:module, :alpha}
    assert bar.scope == {:function, :alpha, :bar, 1}
    assert error.scope == {:result, :alpha, :bar, 1, :error}
    assert call.scope == {:call, 2}
  end

  test "in_scope? matches each level of the tree" do
    call = entry(2, :alpha, :bar, 1, {:exception, {:error, :boom}})

    assert Tree.in_scope?({:module, :alpha}, call)
    assert Tree.in_scope?({:function, :alpha, :bar, 1}, call)
    refute Tree.in_scope?({:function, :alpha, :bar, 2}, call)
    assert Tree.in_scope?({:result, :alpha, :bar, 1, :error}, call)
    refute Tree.in_scope?({:result, :alpha, :bar, 1, :ok}, call)
    assert Tree.in_scope?({:call, 2}, call)
    refute Tree.in_scope?({:call, 1}, call)
    refute Tree.in_scope?({:module, :beta}, call)
  end

  test "rows show a node's children only when it is open" do
    %{nodes: nodes} = Tree.build(entries())

    assert [{"m:alpha", 0, false}, {"m:beta", 0, false}] =
             nodes |> Tree.rows(MapSet.new()) |> Enum.map(&{&1.node.id, &1.depth, &1.open?})

    assert [
             {"m:alpha", 0, true},
             {"f:alpha:bar/1", 1, true},
             {"r:alpha:bar/1:error", 2, false},
             {"r:alpha:bar/1:ok", 2, false},
             {"f:alpha:baz/0", 1, false},
             {"m:beta", 0, false}
           ] =
             nodes
             |> Tree.rows(MapSet.new(["m:alpha", "f:alpha:bar/1"]))
             |> Enum.map(&{&1.node.id, &1.depth, &1.open?})

    assert [{"c:2", 3, false}] =
             nodes
             |> Tree.rows(MapSet.new(["m:alpha", "f:alpha:bar/1", "r:alpha:bar/1:error"]))
             |> Enum.filter(&(&1.depth == 3))
             |> Enum.map(&{&1.node.id, &1.depth, &1.open?})
  end

  test "find returns a node at any level, or nil" do
    %{nodes: nodes} = Tree.build(entries())

    assert %{calls: 1} = Tree.find(nodes, "c:2")
    assert %{calls: 1} = Tree.find(nodes, "r:alpha:bar/1:error")
    assert %{calls: 2} = Tree.find(nodes, "f:alpha:bar/1")
    assert %{calls: 3} = Tree.find(nodes, "m:alpha")
    assert Tree.find(nodes, "c:99") == nil
  end
end
