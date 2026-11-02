defmodule Beamdash.LogsTreeTest do
  use ExUnit.Case, async: true

  alias Beamdash.Logs.Tree

  @t0 ~U[2026-11-01 10:00:00Z]

  defp e(id, seconds, level, where, message) do
    %{
      id: id,
      at: DateTime.add(@t0, seconds, :second),
      level: level,
      pid: nil,
      where: where,
      message: message,
      meta: [],
      raw: message
    }
  end

  # newest first, as Beamdash.Logs keeps them
  defp entries do
    [
      e(7, 60, :error, "MyApp.Repo:query/2", "timeout after 5000 ms"),
      e(6, 55, :critical, "MyApp.Repo:checkout/1", "timeout after 4000 ms"),
      e(5, 40, :info, "MyApp.Web:call/2", "GET /users/12 200"),
      e(4, 30, :warning, "lists:foo/1", "odd 3"),
      e(3, 20, :info, nil, "plain text line"),
      e(2, 10, :info, "Unlisted:run/0", "started"),
      e(1, 0, :info, "MyApp.Web:call/2", "GET /users/9 200")
    ]
  end

  defp apps, do: Tree.apps_map([{:my_app, [MyApp.Repo, MyApp.Web]}, {:stdlib, [:lists]}])

  defp same_time?(at, seconds), do: DateTime.compare(at, DateTime.add(@t0, seconds)) == :eq

  defp labels(nodes), do: Enum.map(nodes, & &1.label)

  test "apps_map names Elixir modules without the Elixir. prefix" do
    assert apps() == %{"MyApp.Repo" => "my_app", "MyApp.Web" => "my_app", "lists" => "stdlib"}
    assert Tree.apps_map(:bad) == %{}
  end

  test "module_of reads the logger handler's source and a JSON line's module" do
    assert Tree.module_of("MyApp.Repo:query/2") == "MyApp.Repo"
    assert Tree.module_of("lists:foo/1") == "lists"
    assert Tree.module_of("Elixir.Foo.Bar") == "Foo.Bar"
    assert Tree.module_of("Foo") == "Foo"
    assert Tree.module_of("  ") == nil
    assert Tree.module_of(nil) == nil
  end

  test "application → module → template, the most problems first" do
    tree = Tree.build(entries(), apps: apps())

    assert labels(tree.nodes) == ["my_app", "stdlib", "application unknown", "no source"]
    assert %{lines: 7, modules: 4, templates: 6} = tree
    {oldest, newest} = tree.window
    assert same_time?(oldest, 0) and same_time?(newest, 60)

    [my_app | _] = tree.nodes
    assert %{count: 4, problems: 2, warnings: 0, kind: :app} = my_app
    assert labels(my_app.children) == ["MyApp.Repo", "MyApp.Web"]

    [repo, web] = my_app.children
    # each function gets its own branch, the most problems first
    assert [%{label: "checkout/1", kind: :function}, %{label: "query/2", kind: :function}] =
             repo.children

    [_checkout, query] = repo.children

    assert [%{label: "timeout after # ms", count: 1, problems: 1, kind: :template} = t] =
             query.children

    assert t.sample.id == 7
    assert same_time?(t.first_at, 60) and same_time?(t.last_at, 60)

    assert [%{label: "call/2", kind: :function, children: [%{label: "GET /users/# #", count: 2}]}] =
             web.children

    stdlib = Enum.find(tree.nodes, &(&1.label == "stdlib"))
    assert %{warnings: 1, problems: 0} = stdlib

    # a line without a source has no module level
    no_source = List.last(tree.nodes)
    assert [%{kind: :template, label: "plain text line"}] = no_source.children
  end

  test "the sparkline spreads the lines over the window" do
    tree = Tree.build(entries(), apps: apps())
    [my_app | _] = tree.nodes
    assert length(my_app.spark) == 24
    assert Enum.sum(my_app.spark) == 4
    assert hd(my_app.spark) == 1
    assert List.last(my_app.spark) == 1

    assert Tree.spark_text([0, 1, 4, 8]) == " ▁▄█"
    assert Tree.spark_text([]) == ""
  end

  test "templates first seen after since are new, and parents count them" do
    tree = Tree.build(entries(), apps: apps(), since: DateTime.add(@t0, 50, :second))
    # checkout/1 and query/2 each have a template first seen after `since`
    assert tree.new == 2
    [my_app | _] = tree.nodes
    assert my_app.new == 2
    assert [%{new: 1}, %{new: 1}] = hd(my_app.children).children
    assert Tree.build(entries(), apps: apps()).new == 0
  end

  test "rows open only the open nodes; find and parent_ids" do
    tree = Tree.build(entries(), apps: apps())
    [my_app | _] = tree.nodes

    assert tree.nodes |> Tree.rows(MapSet.new()) |> length() == 4

    rows = Tree.rows(tree.nodes, MapSet.new([my_app.id]))

    assert Enum.map(Enum.take(rows, 3), &{&1.node.label, &1.depth}) ==
             [{"my_app", 0}, {"MyApp.Repo", 1}, {"MyApp.Web", 1}]

    all = Tree.rows(tree.nodes, MapSet.new(Tree.parent_ids(tree.nodes)))
    assert length(all) == 4 + 4 + 5 + 6

    repo = hd(my_app.children)
    assert Tree.find(tree.nodes, repo.id) == repo
    assert Tree.find(tree.nodes, "nope") == nil
  end

  test "in_scope? matches a node's lines" do
    [e7, _e6, e5, _e4, e3 | _] = entries()

    assert Tree.in_scope?({:app, "my_app"}, e7, apps())
    refute Tree.in_scope?({:app, "stdlib"}, e7, apps())
    assert Tree.in_scope?({:module, "my_app", "MyApp.Repo"}, e7, apps())
    refute Tree.in_scope?({:module, "my_app", "MyApp.Repo"}, e5, apps())
    assert Tree.in_scope?({:function, "my_app", "MyApp.Repo", "query/2"}, e7, apps())
    refute Tree.in_scope?({:function, "my_app", "MyApp.Repo", "query/2"}, e5, apps())

    assert Tree.in_scope?(
             {:template, "my_app", "MyApp.Repo", "query/2", "timeout after # ms"},
             e7,
             apps()
           )

    assert Tree.in_scope?({:template, "no source", nil, nil, "plain text line"}, e3, apps())

    assert Tree.scope_label({:template, "no source", nil, nil, "plain text line"}) ==
             "no source › plain text line"

    assert Tree.scope_label({:function, "my_app", "MyApp.Repo", "query/2"}) ==
             "my_app › MyApp.Repo › query/2"

    assert Tree.scope_label({:module, "my_app", "MyApp.Repo"}) == "my_app › MyApp.Repo"
  end

  test "template_cache keeps each line's template, so only new lines are masked" do
    tree = Tree.build(entries(), apps: apps())
    assert map_size(tree.template_cache) == 7

    # a cached template is used as it is
    [e7 | _] = entries()
    key = {e7.id, :erlang.phash2(e7.message)}
    cache = Map.put(tree.template_cache, key, "cached kind")
    again = Tree.build(entries(), apps: apps(), template_cache: cache)
    [my_app | _] = again.nodes
    templates = Enum.flat_map(hd(my_app.children).children, & &1.children)
    assert "cached kind" in Enum.map(templates, & &1.label)
  end

  test "a line with only an mfa gets its module and a function branch" do
    tree = Tree.build([e(1, 0, :info, "Elixir.Foo.Bar:run/2", "x")], apps: apps())

    [unknown] = tree.nodes
    assert unknown.label == "application unknown"
    assert [%{label: "Foo.Bar", kind: :module, children: [fun]}] = unknown.children
    assert %{label: "run/2", kind: :function, children: [%{label: "x", kind: :template}]} = fun
  end

  test "an empty buffer" do
    assert %{nodes: [], lines: 0, window: nil, new: 0} = Tree.build([])
  end
end
