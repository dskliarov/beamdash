defmodule Beamdash.Logs.Tree do
  @moduledoc """
  The Logs tab's Tree: the log lines arranged by where they came from,
  application → module → function → line template, so the part of the
  system that is noisy or failing shows at a glance.

    * The module comes from the line's source (`where`: `Module:fun/arity`
      from the logger handler, or a JSON line's `module`/`logger`/`mfa`), its
      application from the node (`apps`: module name to application, from
      `apps_map/1` of `Beamdash.Target.module_apps/1`). Lines without a
      source (most `kubectl logs` text) go under "#{"no source"}", modules
      the node doesn't list under "#{"application unknown"}".
    * A line whose source names a function goes under a function branch
      (`fun/arity`) of its module; a template is the message with its
      variable parts masked (`Beamdash.Logs.Group.key/1`), within one
      function, so the same message under two functions is two templates.

  Every node counts its lines, problems (error and above) and warnings,
  when it first and last logged, and its lines over the window
  (`spark`, 24 buckets from the oldest line to the newest). A template
  is new when its first line came after `since`; a module or application
  counts its new templates. Children are sorted most problems first, then
  warnings, then lines, and at most 100 are kept per node (`more` says
  how many were left out).
  """

  alias Beamdash.Logs.{Group, Pretty}

  @no_source "no source"
  @unknown_app "application unknown"
  @problem_levels [:error, :critical, :alert, :emergency]
  @buckets 24
  @max_children 100
  @blocks ~w(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)

  # A function, not an attribute: compiled regexes can't be escaped into
  # code on OTP 28 with Elixir < 1.19.
  defp where_regex, do: ~r/^(.+):([^:\/\s]+\/\d+)$/

  @doc "Module name (as a line's source shows it) to application, from `[{app, [module]}]`."
  def apps_map(module_apps) when is_list(module_apps) do
    for {app, mods} <- module_apps,
        is_atom(app) and is_list(mods),
        mod <- mods,
        is_atom(mod),
        into: %{},
        do: {strip(Atom.to_string(mod)), Atom.to_string(app)}
  end

  def apps_map(_), do: %{}

  @doc "The module named by a line's source (`Mod:fun/1`, `Elixir.Mod`, `Mod`), or nil."
  def module_of(nil), do: nil

  def module_of(where) when is_binary(where) do
    case String.trim(where) do
      "" ->
        nil

      where ->
        case Regex.run(where_regex(), where) do
          [_, mod, _fun] -> strip(mod)
          nil -> strip(where)
        end
    end
  end

  @doc "The function and arity a line's source names (`fun/1`), or nil."
  def function_of(%{where: where}) when is_binary(where) do
    case Regex.run(where_regex(), String.trim(where)) do
      [_, _mod, fun] -> fun
      nil -> nil
    end
  end

  def function_of(_entry), do: nil

  defp strip("Elixir." <> name), do: name
  defp strip(name), do: name

  @doc "Where a line goes: `{application, module}`, module nil for a line without a source."
  def place(entry, apps) do
    case module_of(entry[:where]) do
      nil -> {@no_source, nil}
      mod -> {Map.get(apps, mod, @unknown_app), mod}
    end
  end

  @doc "A line's template: its message with the variable parts masked."
  def template(entry), do: elem(Group.key(entry), 2)

  @doc """
  True when the line is in the part of the tree `scope` names:
  `{:app, app}`, `{:module, app, module}`, `{:function, app, module, fun}`
  or `{:template, app, module, fun, template}` (a node's `scope`).
  """
  def in_scope?({:app, app}, entry, apps), do: elem(place(entry, apps), 0) == app
  def in_scope?({:module, app, mod}, entry, apps), do: place(entry, apps) == {app, mod}

  def in_scope?({:function, app, mod, fun}, entry, apps),
    do: place(entry, apps) == {app, mod} and function_of(entry) == fun

  def in_scope?({:template, app, mod, fun, template}, entry, apps),
    do:
      place(entry, apps) == {app, mod} and function_of(entry) == fun and
        template(entry) == template

  def in_scope?({:field, app, mod, fun, path}, entry, apps),
    do:
      place(entry, apps) == {app, mod} and function_of(entry) == fun and
        grouped?(entry, path)

  def in_scope?({:group_template, app, mod, fun, groups, template}, entry, apps),
    do:
      place(entry, apps) == {app, mod} and function_of(entry) == fun and
        template(entry) == template and grouped?(entry, groups)

  defp grouped?(entry, pairs), do: Enum.all?(pairs, fn {k, v} -> field_value(entry, k) == v end)

  @doc "What a scope shows on its filter chip: `app › module › function › template`."
  def scope_label({:app, app}), do: app
  def scope_label({:module, app, mod}), do: Enum.join([app, mod], " › ")
  def scope_label({:function, app, mod, fun}), do: Enum.join([app, mod, fun], " › ")

  def scope_label({:template, app, mod, fun, template}),
    do: [app, mod, fun, template] |> Enum.reject(&is_nil/1) |> Enum.join(" › ")

  def scope_label({:field, app, mod, fun, path}),
    do: [app, mod, fun | pair_labels(path)] |> Enum.reject(&is_nil/1) |> Enum.join(" › ")

  def scope_label({:group_template, app, mod, fun, groups, template}),
    do:
      [app, mod, fun | pair_labels(groups) ++ [template]]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" › ")

  defp pair_labels(pairs), do: for({key, value} <- pairs, do: field_label(key, value))

  @doc """
  The tree of `entries` (newest first): `%{nodes, lines, modules,
  templates, new, window, template_cache}`, `window` the `{oldest, newest}` line times
  (nil when no line has one). A node is `%{id, kind, label, scope, count,
  problems, warnings, levels, first_at, last_at, spark, new, children,
  more, sample}`; `kind` is `:app`, `:module` or `:template`, `sample` a
  template's newest line.

  Options: `apps` (`apps_map/1`), `since` (a `DateTime`: templates first
  seen after it are new), `template_cache` (the previous result's: each
  line's template by id and message, so only new lines are masked).
  """
  def build(entries, opts \\ []) do
    apps = Keyword.get(opts, :apps, %{})
    group_keys = Keyword.get(opts, :group_keys, [])
    hidden = Keyword.get(opts, :hidden, [])
    entries = Enum.reject(entries, &Enum.any?(hidden, fn scope -> in_scope?(scope, &1, apps) end))
    since = opts[:since] && DateTime.to_unix(opts[:since], :microsecond)
    times = for %{at: %DateTime{} = at} <- entries, do: DateTime.to_unix(at, :microsecond)
    window = if times != [], do: {Enum.min(times), Enum.max(times)}

    cache = Keyword.get(opts, :template_cache, %{})
    keyed = for entry <- entries, do: {entry, cached_template(entry, cache)}

    leaves =
      Enum.reduce(keyed, %{}, fn {entry, {_key, template}}, acc ->
        {app, mod} = place(entry, apps)
        s = line_stats(entry, window)
        groups = groups_of(entry, group_keys)
        Map.update(acc, {app, mod, function_of(entry), groups, template}, s, &merge(&1, s))
      end)

    template_nodes =
      for {{app, mod, fun, groups, template}, s} <- leaves do
        new = if since && s.first && s.first > since, do: 1, else: 0
        scope = template_scope(app, mod, fun, groups, template)
        {{app, mod}, fun, groups, node(:template, template, scope, s, [], new)}
      end

    nodes_by_module = Enum.group_by(template_nodes, &elem(&1, 0))

    modules =
      for {{app, mod}, items} <- nodes_by_module, mod != nil do
        {app, parent(:module, mod, {:module, app, mod}, module_children(app, mod, items))}
      end

    # a line without a source has no module: its templates hang off the app
    loose =
      for {{app, nil}, items} <- nodes_by_module,
          child <- module_children(app, nil, items),
          do: {app, child}

    nodes =
      (modules ++ loose)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {app, children} -> parent(:app, app, {:app, app}, children) end)
      |> sort()

    %{
      nodes: nodes,
      lines: length(entries),
      modules: length(modules),
      templates: map_size(leaves),
      new: Enum.reduce(nodes, 0, &(&1.new + &2)),
      window: window && {datetime(elem(window, 0)), datetime(elem(window, 1))},
      template_cache: Map.new(keyed, fn {_entry, key_template} -> key_template end)
    }
  end

  # the children of a module (or of the app, for a line without a source):
  # each function's branch, then the lines outside any function
  defp module_children(app, mod, items) do
    items
    |> Enum.group_by(fn {_, fun, _, _} -> fun end, fn {_, _, groups, node} -> {groups, node} end)
    |> Enum.flat_map(fn {fun, sub} ->
      nested = nest(sub, app, mod, fun, [])

      if fun == nil,
        do: nested,
        else: [parent(:function, fun, {:function, app, mod, fun}, nested)]
    end)
  end

  # the templates of a function, under a branch per checked field value
  defp nest(items, app, mod, fun, prefix) do
    {done, rest} = Enum.split_with(items, fn {groups, _} -> groups == [] end)
    templates = for {_, node} <- done, do: node

    fields =
      rest
      |> Enum.group_by(fn {[pair | _], _} -> pair end, fn {[_ | tail], node} -> {tail, node} end)
      |> Enum.map(fn {{key, value} = pair, sub} ->
        path = prefix ++ [pair]
        children = nest(sub, app, mod, fun, path)
        parent(:field, field_label(key, value), {:field, app, mod, fun, path}, children)
      end)

    templates ++ fields
  end

  defp template_scope(app, mod, fun, [], template), do: {:template, app, mod, fun, template}

  defp template_scope(app, mod, fun, groups, template),
    do: {:group_template, app, mod, fun, groups, template}

  defp groups_of(_entry, []), do: []

  defp groups_of(entry, keys), do: for(key <- keys, do: {key, field_value(entry, key)})

  defp field_label(key, nil), do: "#{key} = (none)"
  defp field_label(key, value), do: "#{key} = #{value}"

  @doc "The value of the entry's field `key`, or nil."
  def field_value(entry, key) do
    entry
    |> entry_fields()
    |> Enum.find_value(fn {k, v} -> k == key && v end)
  end

  defp entry_fields(entry), do: entry[:fields] || Pretty.all_fields(entry[:message] || "")

  defp cached_template(entry, cache) do
    key = {entry[:id], :erlang.phash2(entry[:message])}

    case Map.fetch(cache, key) do
      {:ok, template} -> {key, template}
      :error -> {key, template(entry)}
    end
  end

  defp line_stats(entry, window) do
    at =
      case entry[:at] do
        %DateTime{} = at -> DateTime.to_unix(at, :microsecond)
        _ -> nil
      end

    %{
      count: 1,
      levels: %{entry[:level] => 1},
      first: at,
      last: at,
      spark: if(at && window, do: %{bucket(at, window) => 1}, else: %{}),
      sample: entry
    }
  end

  defp bucket(_at, {from, from}), do: @buckets - 1
  defp bucket(at, {from, to}), do: min(div((at - from) * @buckets, to - from + 1), @buckets - 1)

  # entries come newest first, so `a` already holds the newest sample
  defp merge(a, b) do
    %{
      count: a.count + b.count,
      levels: Map.merge(a.levels, b.levels, fn _, x, y -> x + y end),
      first: pick(a.first, b.first, &min/2),
      last: pick(a.last, b.last, &max/2),
      spark: Map.merge(a.spark, b.spark, fn _, x, y -> x + y end),
      sample: a.sample || b.sample
    }
  end

  defp pick(nil, b, _fun), do: b
  defp pick(a, nil, _fun), do: a
  defp pick(a, b, fun), do: fun.(a, b)

  defp parent(kind, label, scope, children) do
    s =
      children
      |> Enum.map(fn child ->
        spark = for {n, i} <- Enum.with_index(child.spark), n > 0, into: %{}, do: {i, n}

        child
        |> Map.take([:count, :levels, :first, :last])
        |> Map.merge(%{spark: spark, sample: nil})
      end)
      |> Enum.reduce(&merge(&2, &1))

    node(kind, label, scope, s, children, Enum.sum(Enum.map(children, & &1.new)))
  end

  defp node(kind, label, scope, s, children, new) do
    sorted = sort(children)

    %{
      id: "t#{:erlang.phash2(scope, 4_294_967_296)}",
      kind: kind,
      label: label,
      scope: scope,
      count: s.count,
      problems: s.levels |> Map.take(@problem_levels) |> Map.values() |> Enum.sum(),
      warnings: Map.get(s.levels, :warning, 0),
      levels: s.levels,
      first: s.first,
      last: s.last,
      first_at: s.first && datetime(s.first),
      last_at: s.last && datetime(s.last),
      spark: for(i <- 0..(@buckets - 1), do: Map.get(s.spark, i, 0)),
      new: new,
      children: Enum.take(sorted, @max_children),
      more: max(length(sorted) - @max_children, 0),
      sample: if(kind == :template, do: s.sample)
    }
  end

  defp sort(nodes), do: Enum.sort_by(nodes, &{-&1.problems, -&1.warnings, -&1.count, &1.label})

  defp datetime(us), do: DateTime.from_unix!(us, :microsecond)

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

  @doc "The ids of the nodes that have children (to open them all)."
  def parent_ids(nodes) do
    for node <- nodes, node.children != [], id <- [node.id | parent_ids(node.children)], do: id
  end

  @doc "A node's sparkline as block characters, scaled to its busiest bucket (a space for none)."
  def spark_text(counts) do
    top = Enum.max(counts, fn -> 0 end)

    Enum.map_join(counts, fn
      0 -> " "
      n -> Enum.at(@blocks, min(div(n * length(@blocks) - 1, max(top, 1)), length(@blocks) - 1))
    end)
  end
end
