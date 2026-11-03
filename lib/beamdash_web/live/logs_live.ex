defmodule BeamdashWeb.LogsLive do
  @moduledoc """
  The target's log lines (`Beamdash.Logs`), oldest first, with a level and
  a text filter, repeated lines combined into one row (`Beamdash.Logs.Group`),
  a group's original lines on Expand, "Show all like this" (a pattern
  filter), and Copy / Download of the original lines (the `LogExport` hook).

  The rows are a LiveView stream (`:rows`, at most 1,000 rendered). Each
  item is a group row from `Group.group/1` or, with grouping off or a
  pattern set, a single-entry row `%{id: "e-<id>", ...}`; Previous container
  rows are prefixed `p-` so DOM ids never collide with the live ones. Any
  filter, pattern, grouping or view change rebuilds the stream; new lines
  are appended at the bottom, a similar one joining one of the 4 newest rows
  (`Group.add/2`) and moving that row to the bottom.

  A batch of new lines is folded into the rows first, then each new or moved
  row is inserted once; a row that joins without moving is updated in place.
  `@window` holds the newest rows, the ones a line can join. When lines leave
  the 2,000-line buffer, every rendered row (`@rendered`: DOM row id to the
  row, with its line ids) drops the evicted ids, and rows whose lines have all
  left are deleted. A rendered row's id can then be older than the one
  `Group.group/1` gives, so row events also carry the row's newest entry id
  (`phx-value-entry`) and `find_row` falls back to it.

  An expanded group keeps the lines it was expanded with (`@expanded`: DOM
  row id to a snapshot of its lines, already masked, and its newest entry
  id then). Newer similar lines only change its header: the count, the
  newest text and a "+N newer" button, Refresh, which takes a new
  snapshot. A snapshot is also found by its newest entry id, so a row
  whose id changed (a rebuild after evictions) stays expanded.

  The Tree tab (`@tab`) shows the same lines, through the level and text
  filters, as `Beamdash.Logs.Tree` (application → module → kind of line),
  rebuilt at most every second while lines arrive; the node's module →
  application map (`@tree_apps`) is read once per connection. A node's
  Lines button scopes the Lines tab to its lines (`@scope`, a chip like
  the pattern's). The Crashes tab shows `Beamdash.Logs.Cascade`'s
  incidents the same way, asking the node once per connection for the
  supervisors of crashed names no line gave (`@cascade_known`); its Lines
  buttons scope Lines to an incident's time window or a process's crash
  lines. Neither renders the table, so going back to Lines rebuilds the
  stream.

  The page keeps the live entries it has shown (`@entries`, newest first)
  and the Previous container's separately (`@previous`). `mount` reads
  `session["logs_server"]` and `session["target"]` (tests) or uses
  `Beamdash.Logs` and `Beamdash.Target`.
  """
  use Phoenix.LiveView

  alias Beamdash.{Format, Logs, Target}
  alias Beamdash.Logs.{Cascade, Filter, Group, Pretty, Tree}

  @max_rows 1_000
  @max_entries 2_000
  # the Tree and Crashes are rebuilt at most this often while lines arrive
  @tree_ms 1_000
  # Lines of a crash incident: its lines and this much around them
  @around_us 2_000_000
  @levels ~w(debug info notice warning error)
  # what an application's level can be set to, most verbose first
  @app_levels ~w(default all debug info notice warning error critical alert emergency none)

  @impl true
  def mount(_params, session, socket) do
    logs = session["logs_server"] || Logs
    target = session["target"] || Target
    %{status: status, node: node} = Target.status(target)

    socket =
      socket
      |> assign(
        logs: logs,
        target: target,
        status: status,
        node: node,
        info: Logs.info(logs),
        filter_text: "",
        filter: Filter.parse(""),
        min_level: nil,
        pattern: nil,
        group?: true,
        paused?: false,
        pending: 0,
        view: :live,
        entries: [],
        newest_id: 0,
        previous: nil,
        previous_loading?: false,
        previous_error: nil,
        expanded: %{},
        open: MapSet.new(),
        window: [],
        rendered: %{},
        export_note: nil,
        source_error: nil,
        source_loading?: false,
        source_ref: nil,
        total: 0,
        shown: 0,
        no_level: 0,
        app_levels_open?: false,
        app_levels: nil,
        app_levels_loading?: false,
        app_levels_error: nil,
        app_level_note: nil,
        tab: :lines,
        tree: nil,
        tree_open: nil,
        tree_detail: MapSet.new(),
        tree_group_keys: [],
        tree_hidden: [],
        tree_checked: [],
        tree_apps: %{},
        tree_apps_node: nil,
        tree_apps_error: nil,
        tree_since: nil,
        tree_timer: nil,
        cascades: nil,
        cascade_known: %{},
        tree_cache: %{},
        cascade_cache: %{},
        cascade_asking?: false,
        scope: nil
      )
      |> stream(:rows, [])

    if connected?(socket) do
      :ok = Target.subscribe(target)
      :ok = Logs.subscribe(logs)
      {:ok, socket |> load_live() |> reset_rows()}
    else
      {:ok, socket}
    end
  end

  ## Events

  # the Copy note shows until the next event
  @impl true
  def handle_event(name, params, socket),
    do: event(name, params, assign(socket, export_note: nil))

  defp event("filter", %{"q" => text}, socket) when is_binary(text) do
    {:noreply, socket |> assign(filter_text: text, filter: Filter.parse(text)) |> reset_rows()}
  end

  defp event("level", %{"level" => level}, socket) do
    min_level = if level in @levels, do: String.to_existing_atom(level)
    {:noreply, socket |> assign(min_level: min_level) |> reset_rows()}
  end

  # the checked key=value pairs of a details panel join the filter text
  defp event("field_filter", params, socket) do
    text =
      params
      |> Map.get("pairs", [])
      |> Enum.map(&Filter.pair_term/1)
      |> Enum.reject(&String.contains?(socket.assigns.filter_text, &1))
      |> Enum.reduce(socket.assigns.filter_text, fn term, text ->
        String.trim(text <> " " <> term)
      end)

    {:noreply, socket |> assign(filter_text: text, filter: Filter.parse(text)) |> reset_rows()}
  end

  defp event("clear_filter", _params, socket) do
    {:noreply,
     socket
     |> assign(
       filter_text: "",
       filter: Filter.parse(""),
       min_level: nil,
       pattern: nil,
       scope: nil
     )
     |> reset_rows()}
  end

  defp event("tab", %{"tab" => "tree"}, socket) do
    socket =
      socket
      |> assign(tab: :tree, tree_since: socket.assigns.tree_since || DateTime.utc_now())
      |> load_tree_apps()

    {:noreply, refresh_tree(socket)}
  end

  defp event("tab", %{"tab" => "crashes"}, socket),
    do: {:noreply, socket |> assign(tab: :crashes) |> refresh_tree()}

  defp event("tab", %{"tab" => "lines"}, socket),
    do: {:noreply, socket |> assign(tab: :lines) |> reset_rows()}

  defp event("tree_toggle", %{"id" => id}, socket) do
    {:noreply, assign(socket, tree_open: toggle(tree_open(socket.assigns), id))}
  end

  defp event("tree_detail", %{"id" => id}, socket) do
    {:noreply, assign(socket, tree_detail: toggle(socket.assigns.tree_detail, id))}
  end

  defp event("tree_check", %{"key" => key, "val" => value}, socket) do
    pair = {key, value}
    checked = socket.assigns.tree_checked

    checked =
      if pair in checked, do: List.delete(checked, pair), else: checked ++ [pair]

    {:noreply, assign(socket, tree_checked: checked)}
  end

  defp event("tree_filter", _params, socket) do
    pairs = Enum.map(socket.assigns.tree_checked, fn {key, value} -> "#{key}=#{value}" end)
    event("field_filter", %{"pairs" => pairs}, socket)
  end

  defp event("tree_regroup", _params, socket) do
    keys = socket.assigns.tree_checked |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    {:noreply, socket |> assign(tree_group_keys: keys) |> refresh_tree()}
  end

  defp event("tree_ungroup", _params, socket),
    do: {:noreply, socket |> assign(tree_group_keys: [], tree_hidden: []) |> refresh_tree()}

  # a branch added by regrouping is removed: its lines leave the tree
  defp event("tree_hide_branch", %{"id" => id}, %{assigns: %{tree: %{nodes: nodes}}} = socket) do
    case Tree.find(nodes, id) do
      %{kind: :field, scope: scope} ->
        hidden = Enum.uniq(socket.assigns.tree_hidden ++ [scope])
        {:noreply, socket |> assign(tree_hidden: hidden) |> refresh_tree()}

      _ ->
        {:noreply, socket}
    end
  end

  defp event("tree_restore", _params, socket),
    do: {:noreply, socket |> assign(tree_hidden: []) |> refresh_tree()}

  defp event("tree_expand_all", _params, %{assigns: %{tree: %{nodes: nodes}}} = socket),
    do: {:noreply, assign(socket, tree_open: MapSet.new(Tree.parent_ids(nodes)))}

  defp event("tree_collapse_all", _params, socket),
    do: {:noreply, assign(socket, tree_open: MapSet.new())}

  # "Show lines": the Lines tab, scoped to the node's lines
  defp event("tree_show", %{"id" => id}, %{assigns: %{tree: %{nodes: nodes}}} = socket) do
    case Tree.find(nodes, id) do
      nil -> {:noreply, socket}
      node -> {:noreply, socket |> assign(tab: :lines, scope: node.scope) |> reset_rows()}
    end
  end

  # an incident's Lines: the lines around it; a node's: its own lines
  defp event("crash_lines", %{"id" => id} = params, %{assigns: %{cascades: [_ | _]}} = socket) do
    case Enum.find(socket.assigns.cascades, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      incident ->
        scope =
          case params["name"] && Enum.find(incident.rows, &(&1.node.name == params["name"])) do
            %{node: node} ->
              {:ids, "crashes of #{node.name}", MapSet.new(node.entry_ids)}

            _ ->
              {:window, "crashes #{clock(incident.from)}–#{clock(incident.to)}",
               DateTime.add(incident.from, -@around_us, :microsecond),
               DateTime.add(incident.to, @around_us, :microsecond)}
          end

        {:noreply, socket |> assign(tab: :lines, scope: scope) |> reset_rows()}
    end
  end

  defp event("clear_scope", _params, socket),
    do: {:noreply, socket |> assign(scope: nil) |> reset_rows()}

  defp event("toggle_group", _params, socket) do
    {:noreply, socket |> assign(group?: not socket.assigns.group?) |> reset_rows()}
  end

  defp event("pause", _params, socket),
    do: {:noreply, assign(socket, paused?: true, pending: 0)}

  defp event("resume", _params, socket) do
    socket = socket |> assign(paused?: false, pending: 0) |> load_live()
    {:noreply, if(socket.assigns.view == :live, do: reset_rows(socket), else: socket)}
  end

  defp event("clear", _params, socket) do
    :ok = Logs.clear(socket.assigns.logs)
    {:noreply, cleared(socket)}
  end

  defp event("reconnect", _params, socket) do
    :ok = Logs.reconnect(socket.assigns.logs)
    {:noreply, assign(socket, info: Logs.info(socket.assigns.logs))}
  end

  defp event("set_source", %{"source" => source}, %{assigns: %{source_loading?: false}} = socket)
       when source in ["combined", "kubectl", "node"] do
    mode = String.to_existing_atom(source)
    logs = socket.assigns.logs
    recipient = self()
    ref = make_ref()

    socket =
      if valid_view?(mode, socket.assigns.view), do: socket, else: to_live(socket)

    {:noreply,
     socket
     |> assign(source_loading?: true, source_error: nil, source_ref: ref)
     |> start_async({:set_source, ref}, fn ->
       case Logs.set_source(mode, logs) do
         :ok -> Logs.send_snapshot(logs, recipient, ref)
         error -> error
       end
     end)}
  end

  defp event("set_source", _params, socket), do: {:noreply, socket}

  defp event("toggle_app_levels", _params, socket) do
    if socket.assigns.app_levels_open? do
      {:noreply, assign(socket, app_levels_open?: false, app_level_note: nil)}
    else
      {:noreply, socket |> assign(app_levels_open?: true) |> load_app_levels()}
    end
  end

  # only an application the node listed and a known level: the names
  # come from the browser, so they are never made into new atoms
  defp event("set_app_level", %{"app" => app, "level" => level}, socket)
       when level in @app_levels do
    with %{apps: apps} <- socket.assigns.app_levels,
         {app, _} <- Enum.find(apps, fn {a, _} -> Atom.to_string(a) == app end) do
      target = socket.assigns.target
      level = String.to_existing_atom(level)

      {:noreply,
       start_async(socket, :set_app_level, fn ->
         {app, level, Target.set_app_log_level(app, level, target)}
       end)}
    else
      _ -> {:noreply, socket}
    end
  end

  defp event("set_app_level", _params, socket), do: {:noreply, socket}

  defp event("set_primary_level", %{"level" => level}, socket)
       when level in @app_levels and level != "default" do
    target = socket.assigns.target
    level = String.to_existing_atom(level)

    {:noreply,
     start_async(socket, :set_primary_level, fn ->
       {level, Target.set_primary_log_level(level, target)}
     end)}
  end

  defp event("set_primary_level", _params, socket), do: {:noreply, socket}

  defp event("view", %{"view" => "previous"}, socket) do
    server = socket.assigns.logs

    {:noreply,
     socket
     |> assign(
       view: :previous,
       previous: nil,
       previous_loading?: true,
       previous_error: nil,
       open: MapSet.new()
     )
     |> reset_rows()
     |> start_async(:previous, fn -> Logs.previous(server) end)}
  end

  defp event("view", %{"view" => "live"}, socket), do: {:noreply, to_live(socket)}

  defp event("toggle_row", %{"id" => id} = params, socket) do
    a = socket.assigns

    case find_row(a, id, params["entry"]) do
      nil ->
        {:noreply, socket}

      row ->
        expanded =
          case expanded_key(a, row) do
            nil -> Map.put(a.expanded, row.id, snapshot(a, row))
            key -> Map.delete(a.expanded, key)
          end

        {:noreply, socket |> assign(expanded: expanded) |> update_row(row)}
    end
  end

  # "+N newer": the expanded group's lines again, with the newer ones
  defp event("refresh_row", %{"id" => id} = params, socket) do
    a = socket.assigns

    with row when row != nil <- find_row(a, id, params["entry"]),
         key when key != nil <- expanded_key(a, row) do
      expanded = a.expanded |> Map.delete(key) |> Map.put(row.id, snapshot(a, row))
      {:noreply, socket |> assign(expanded: expanded) |> update_row(row)}
    else
      _ -> {:noreply, socket}
    end
  end

  defp event("toggle_entry", %{"id" => id} = params, socket) do
    with {entry_id, ""} <- Integer.parse(id),
         row when row != nil <- find_row(socket.assigns, params["row"], entry_id) do
      socket = assign(socket, open: toggle(socket.assigns.open, entry_id))
      {:noreply, update_row(socket, row)}
    else
      _ -> {:noreply, socket}
    end
  end

  defp event("like", %{"id" => id} = params, socket) do
    case find_row(socket.assigns, id, params["entry"]) do
      nil -> {:noreply, socket}
      row -> {:noreply, socket |> assign(pattern: row.key) |> reset_rows()}
    end
  end

  defp event("clear_pattern", _params, socket),
    do: {:noreply, socket |> assign(pattern: nil) |> reset_rows()}

  defp event("export", %{"id" => id, "mode" => mode} = params, socket)
       when mode in ["copy", "download"] do
    case export_entries(socket.assigns, id, params["entry"]) do
      [] ->
        {:noreply, socket}

      entries ->
        {:noreply,
         push_event(socket, "logs-export", %{
           name: export_name(socket.assigns.node),
           text: Enum.map_join(entries, "\n", & &1.raw),
           lines: length(entries),
           mode: mode
         })}
    end
  end

  # from the LogExport hook after a copy: %{"ok" => bool, "lines" => n},
  # with "reason" => "no_clipboard" when the browser has no clipboard API.
  # Whatever else comes is a failed copy, never a crash.
  defp event("export_done", %{"ok" => ok} = params, socket) when ok in [true, "true"] do
    note =
      case parse_id(params["lines"]) do
        1 -> {:ok, "Copied 1 line"}
        n when is_integer(n) -> {:ok, "Copied #{n} lines"}
        _ -> {:ok, "Copied"}
      end

    {:noreply, assign(socket, export_note: note)}
  end

  defp event("export_done", %{"reason" => "no_clipboard"}, socket),
    do:
      {:noreply,
       assign(socket,
         export_note: {:error, "Copy failed: the clipboard needs HTTPS or localhost"}
       )}

  defp event("export_done", _params, socket),
    do: {:noreply, assign(socket, export_note: {:error, "Copy failed"})}

  defp event(name, _params, socket)
       when name in ["tab", "tree_expand_all", "tree_show", "crash_lines"],
       do: {:noreply, socket}

  ## Background load of the Previous container

  @impl true
  def handle_async({:set_source, _ref}, {:ok, :ok}, socket), do: {:noreply, socket}

  def handle_async({:set_source, ref}, result, %{assigns: %{source_ref: ref}} = socket) do
    {:noreply,
     assign(socket,
       source_ref: nil,
       source_loading?: false,
       source_error: "Could not change log source: #{async_error(result)}"
     )}
  end

  def handle_async({:set_source, _}, _result, socket), do: {:noreply, socket}

  def handle_async(:previous, {:ok, {:ok, entries}}, %{assigns: %{view: :previous}} = socket) do
    {:noreply, socket |> assign(previous: entries, previous_loading?: false) |> reset_rows()}
  end

  def handle_async(:previous, result, %{assigns: %{view: :previous}} = socket) do
    reason =
      case result do
        {:ok, {:error, reason}} -> reason
        {:ok, other} -> other
        {:exit, reason} -> reason
      end

    {:noreply,
     assign(socket,
       previous: [],
       previous_loading?: false,
       previous_error: "Could not load the previous container: #{previous_error(reason)}"
     )}
  end

  # the user went back to Live meanwhile
  def handle_async(:previous, _result, socket), do: {:noreply, socket}

  # (the header's level is read when the stream attaches: keep it current)
  def handle_async(:app_levels, {:ok, {:ok, %{primary: primary, apps: _} = levels}}, socket) do
    {:noreply,
     assign(socket,
       app_levels: levels,
       app_levels_loading?: false,
       info: current_level(socket.assigns.info, primary)
     )}
  end

  def handle_async(:app_levels, result, socket) do
    {:noreply,
     assign(socket,
       app_levels: nil,
       app_levels_loading?: false,
       app_levels_error: "Could not read the application levels: #{async_error(result)}"
     )}
  end

  def handle_async(:set_app_level, {:ok, {app, level, {:ok, :ok}}}, socket) do
    note = if level == :default, do: "#{app} reset to the default", else: "#{app} set to #{level}"
    {:noreply, socket |> assign(app_level_note: {:ok, note}) |> load_app_levels()}
  end

  def handle_async(:set_app_level, result, socket) do
    reason =
      case result do
        {:ok, {app, _level, {:ok, {:error, reason}}}} -> "#{app}: #{Format.error(reason)}"
        {:ok, {app, _level, error}} -> "#{app}: #{async_error({:ok, error})}"
        other -> async_error(other)
      end

    {:noreply,
     socket
     |> assign(app_level_note: {:error, "Could not set the level: #{reason}"})
     |> load_app_levels()}
  end

  def handle_async(:set_primary_level, {:ok, {level, {:ok, :ok}}}, socket) do
    note = "Primary level set to #{level}"
    {:noreply, socket |> assign(app_level_note: {:ok, note}) |> load_app_levels()}
  end

  def handle_async(:set_primary_level, result, socket) do
    reason =
      case result do
        {:ok, {_level, {:ok, {:error, reason}}}} -> Format.error(reason)
        {:ok, {_level, error}} -> async_error({:ok, error})
        other -> async_error(other)
      end

    {:noreply,
     socket
     |> assign(app_level_note: {:error, "Could not set the primary level: #{reason}"})
     |> load_app_levels()}
  end

  # (a Lines scope from the tree places lines with the map too)
  def handle_async(:tree_apps, {:ok, {node, {:ok, list}}}, socket)
      when is_list(list) and node == socket.assigns.node do
    socket = assign(socket, tree_apps: Tree.apps_map(list), tree_apps_node: node)

    {:noreply,
     if(tree_scope?(socket.assigns.scope), do: reset_rows(socket), else: refresh_tree(socket))}
  end

  def handle_async(:tree_apps, {:ok, {node, _}}, socket) when node != socket.assigns.node,
    do: {:noreply, socket}

  def handle_async(:tree_apps, result, socket) do
    reason =
      case result do
        {:ok, {_node, other}} -> async_error({:ok, other})
        other -> async_error(other)
      end

    {:noreply,
     assign(socket, tree_apps_error: "Could not read the node's applications: #{reason}")}
  end

  # names the node didn't list (not registered now) stay known as [], so
  # they are asked once per connection; an answer from an earlier node, or
  # an error, records nothing
  def handle_async(:cascade_ancestors, {:ok, {node, names, {:ok, list}}}, socket)
      when is_list(list) and node == socket.assigns.node do
    found = Map.new(list)

    known =
      Enum.reduce(names, socket.assigns.cascade_known, &Map.put(&2, &1, Map.get(found, &1, [])))

    {:noreply, socket |> assign(cascade_known: known, cascade_asking?: false) |> refresh_tree()}
  end

  def handle_async(:cascade_ancestors, _result, socket),
    do: {:noreply, assign(socket, cascade_asking?: false)}

  defp async_error({:ok, {:error, reason}}), do: Format.error(reason)
  defp async_error({:ok, other}), do: inspect(other)
  defp async_error({:exit, reason}), do: Format.error(reason)

  # only a stream that reported a level (a Direct one) shows it
  defp current_level(%{level: nil} = info, _primary), do: info
  defp current_level(info, primary), do: %{info | level: primary}

  defp load_app_levels(socket) do
    target = socket.assigns.target

    socket
    |> assign(app_levels_loading?: true, app_levels_error: nil)
    |> start_async(:app_levels, fn -> Target.log_levels(target) end)
  end

  defp previous_error({status, output}) when is_integer(status) and is_binary(output),
    do: "kubectl exited with #{status}: #{String.trim(output)}"

  defp previous_error(reason), do: Format.error(reason)

  ## Messages

  @impl true
  def handle_info(
        {:beamdash_logs, {:snapshot, ref, info, entries}},
        %{assigns: %{source_ref: ref}} = socket
      ) do
    newest = Enum.reduce(entries, 0, &max(&1.id, &2))

    {:noreply,
     socket
     |> assign(
       info: info,
       entries: entries,
       newest_id: newest,
       source_ref: nil,
       source_loading?: false,
       view: :live,
       previous: nil,
       previous_loading?: false,
       previous_error: nil,
       paused?: false,
       pending: 0,
       source_error: nil,
       scope: lines_scope(socket.assigns.scope)
     )
     |> reset_rows()}
  end

  def handle_info({:beamdash_logs, {:snapshot, _, _, _}}, socket), do: {:noreply, socket}

  def handle_info({:beamdash_logs, {:entries, batch}}, socket) do
    a = socket.assigns

    cond do
      batch == [] ->
        {:noreply, socket}

      a.paused? ->
        {:noreply, assign(socket, pending: a.pending + length(batch))}

      Enum.any?(batch, &(&1.id <= a.newest_id)) ->
        # an entry sent again (a continuation line joined it): start over
        socket = load_live(socket)
        {:noreply, if(a.view == :live, do: reset_rows(socket), else: socket)}

      true ->
        {:noreply, add_entries(socket, batch)}
    end
  end

  def handle_info({:beamdash_logs, :cleared}, socket), do: {:noreply, cleared(socket)}

  def handle_info({:beamdash_logs, {:info, info}}, socket) do
    info =
      case socket.assigns.app_levels do
        %{primary: primary} -> current_level(info, primary)
        nil -> info
      end

    {:noreply, assign(socket, info: info)}
  end

  def handle_info({:beamdash_target, {:connected, node}}, socket) do
    # a new connection may be a restarted node: its applications and
    # processes are read again
    socket =
      assign(socket,
        status: :connected,
        node: node,
        app_level_note: nil,
        cascade_known: %{},
        tree_apps_node: nil
      )

    socket = if socket.assigns.app_levels_open?, do: load_app_levels(socket), else: socket
    a = socket.assigns

    {:noreply,
     if(a.tab == :tree or tree_scope?(a.scope), do: load_tree_apps(socket), else: socket)}
  end

  def handle_info({:beamdash_target, {:disconnected, _}}, socket),
    do: {:noreply, assign(socket, status: :disconnected, app_levels: nil, app_level_note: nil)}

  def handle_info(:rebuild_tree, socket),
    do: {:noreply, socket |> assign(tree_timer: nil) |> refresh_tree()}

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Entries and rows

  # the live entries, from Logs
  defp load_live(socket) do
    entries = Logs.entries(socket.assigns.logs)
    # (from the entries alone: a restarted Logs numbers from 1 again)
    newest = Enum.reduce(entries, 0, &max(&1.id, &2))
    assign(socket, entries: entries, newest_id: newest)
  end

  defp cleared(socket) do
    socket =
      assign(socket,
        entries: [],
        expanded: %{},
        open: MapSet.new(),
        scope: lines_scope(socket.assigns.scope)
      )

    if socket.assigns.view == :live, do: reset_rows(socket), else: socket
  end

  # Newer entries (newest first) on top of the live ones.
  defp add_entries(socket, batch) do
    a = socket.assigns
    all = batch ++ a.entries
    entries = Enum.take(all, @max_entries)

    socket =
      socket
      |> assign(entries: entries, newest_id: max(a.newest_id, hd(batch).id))
      |> schedule_tree()

    if a.view == :live do
      evicted = Enum.drop(all, @max_entries)
      new = batch |> Enum.reverse() |> Enum.filter(&visible?(&1, a))
      shown = a.shown + length(new) - Enum.count(evicted, &visible?(&1, a))
      socket = assign(socket, total: length(entries), shown: shown)

      # the table isn't rendered on Tree or Crashes, and going back to
      # Lines rebuilds it
      if a.tab == :lines, do: insert_rows(socket, new, evicted), else: socket
    else
      socket
    end
  end

  # The batch's visible entries (oldest first) folded into the rows, every
  # row trimmed to the kept entries, each new or changed row inserted once,
  # and the rendered rows whose entries were all evicted deleted.
  defp insert_rows(socket, new, evicted) do
    a = socket.assigns
    gone = MapSet.new(evicted, & &1.id)

    # newest first; the rows past the window stay in the list
    folded =
      if grouped?(a),
        do: Enum.reduce(new, a.window, &Group.add(&2, &1)),
        else: new |> Enum.map(&single/1) |> Enum.reverse()

    fresh = Enum.reject(folded, &(Map.get(a.rendered, &1.id) == &1))
    fresh_ids = MapSet.new(fresh, & &1.id)

    {rendered, touched, emptied} =
      trim_rendered(Map.merge(a.rendered, Map.new(fresh, &{&1.id, &1})), gone, a.entries)

    # the newest row is last in the stream: it stays put when it is also the
    # oldest row of the batch, else a joined row moves to the bottom
    in_place =
      case {List.last(fresh), a.window} do
        {%{id: id}, [%{id: id} | _]} -> id
        _ -> nil
      end

    moved =
      for %{id: id} <- fresh,
          id != in_place,
          Map.has_key?(a.rendered, id),
          Map.has_key?(rendered, id),
          do: id

    deleted = Enum.filter(emptied, &Map.has_key?(a.rendered, &1)) ++ moved

    window =
      if grouped?(a),
        do:
          folded
          |> Enum.map(&Map.get(rendered, &1.id))
          |> Enum.reject(&is_nil/1)
          |> Enum.take(Group.window()),
        else: []

    appended =
      fresh
      |> Enum.reverse()
      |> Enum.filter(&Map.has_key?(rendered, &1.id))
      |> Enum.map(&Map.fetch!(rendered, &1.id))

    updated =
      for id <- touched,
          not MapSet.member?(fresh_ids, id),
          Map.has_key?(rendered, id),
          do: rendered[id]

    socket = assign(socket, rendered: rendered, window: window)
    socket = Enum.reduce(deleted, socket, &stream_delete_by_dom_id(&2, :rows, "rows-" <> &1))

    socket =
      Enum.reduce(
        appended,
        socket,
        &stream_insert(&2, :rows, item(&1, a), at: -1, limit: -@max_rows)
      )

    socket = Enum.reduce(updated, socket, &update_row(&2, &1))

    if emptied == [], do: socket, else: prune_expanded(socket)
  end

  # Drops the snapshots (up to 2,000 lines each) of rows that are no longer
  # rendered.
  defp prune_expanded(%{assigns: %{expanded: expanded}} = socket) when expanded == %{}, do: socket

  defp prune_expanded(%{assigns: a} = socket) do
    live = MapSet.new(Map.keys(a.rendered))
    assign(socket, expanded: Map.filter(a.expanded, fn {key, _} -> MapSet.member?(live, key) end))
  end

  # Trims only the rows holding an evicted entry, since entries leave oldest
  # first. Returns the rows, the ids of the trimmed ones and of those left empty.
  defp trim_rendered(rows, gone, entries) do
    touched =
      if MapSet.size(gone) == 0,
        do: [],
        else: for({id, row} <- rows, Enum.any?(row.ids, &MapSet.member?(gone, &1)), do: id)

    rows =
      Enum.reduce(touched, rows, &Map.update!(&2, &1, fn row -> trim(row, gone, entries) end))

    emptied = for id <- touched, rows[id].ids == [], do: id
    {Map.drop(rows, emptied), touched, emptied}
  end

  # The row without the evicted entries' ids and its count to match. Its id
  # stays, so the DOM row is updated in place.
  defp trim(row, gone, entries) do
    case Enum.reject(row.ids, &MapSet.member?(gone, &1)) do
      ids when length(ids) == length(row.ids) ->
        row

      [] ->
        %{row | ids: [], count: 0}

      ids ->
        oldest = List.last(ids)
        first = Enum.find(entries, &(&1.id == oldest))
        %{row | ids: ids, count: length(ids), first_at: first && first.at}
    end
  end

  # the Previous container exists only for a Kubernetes source
  defp valid_view?(:node, :previous), do: false
  defp valid_view?(_mode, _view), do: true

  defp to_live(socket) do
    socket
    |> assign(view: :live, previous: nil, previous_loading?: false, previous_error: nil)
    |> assign(open: MapSet.new())
    |> reset_rows()
  end

  # Rebuilds the stream from the current view's entries.
  defp reset_rows(socket) do
    a = socket.assigns
    entries = current(a)
    visible = Enum.filter(entries, &visible?(&1, a))
    rows = rows_of(visible, a)
    rendered = Enum.take(rows, @max_rows)
    live? = a.view == :live
    window = if live? and grouped?(a), do: Enum.take(rows, Group.window()), else: []
    rendered_rows = if live?, do: Map.new(rendered, &{&1.id, &1}), else: %{}
    # everything is rendered again: expanded rows show all their lines
    a = %{a | expanded: resnapshot(a, rendered)}

    socket
    |> assign(
      total: length(entries),
      shown: length(visible),
      # lines whose format gave no level: a level filter hides them all
      no_level: if(a.min_level, do: Enum.count(entries, &(&1.level == nil)), else: 0),
      window: window,
      rendered: rendered_rows,
      expanded: a.expanded
    )
    |> stream(:rows, rendered |> Enum.reverse() |> Enum.map(&item(&1, a)), reset: true)
    |> refresh_tree()
  end

  defp resnapshot(%{expanded: expanded} = a, _rows) when expanded == %{}, do: a.expanded

  defp resnapshot(a, rows) do
    Enum.reduce(rows, a.expanded, fn row, acc ->
      case row.count > 1 && expanded_key(%{a | expanded: acc}, row) do
        key when is_binary(key) -> acc |> Map.delete(key) |> Map.put(row.id, snapshot(a, row))
        _ -> acc
      end
    end)
  end

  defp update_row(socket, row),
    do: stream_insert(socket, :rows, item(row, socket.assigns), update_only: true)

  defp current(%{view: :previous, previous: previous}), do: previous || []
  defp current(%{entries: entries}), do: entries

  defp visible?(entry, a) do
    Filter.level_ok?(a.min_level, entry) and Filter.match?(a.filter, entry) and
      (a.pattern == nil or Group.key(entry) == a.pattern) and
      (a.scope == nil or in_scope?(a.scope, entry, a))
  end

  defp in_scope?({:ids, _label, ids}, entry, _a), do: MapSet.member?(ids, entry.id)

  defp in_scope?({:window, _label, from, to}, %{at: %DateTime{} = at}, _a),
    do: DateTime.compare(at, from) != :lt and DateTime.compare(at, to) != :gt

  defp in_scope?({:window, _, _, _}, _entry, _a), do: false
  defp in_scope?(scope, entry, a), do: Tree.in_scope?(scope, entry, a.tree_apps)

  # the lines a crash scope names are gone once the entries are replaced
  defp lines_scope({:ids, _, _}), do: nil
  defp lines_scope(scope), do: scope

  defp tree_scope?(scope),
    do:
      is_tuple(scope) and
        elem(scope, 0) in [:app, :module, :function, :template, :field, :group_template]

  defp scope_label({:ids, label, _}), do: label
  defp scope_label({:window, label, _, _}), do: label
  defp scope_label(scope), do: "tree: " <> Tree.scope_label(scope)

  defp grouped?(a), do: a.group? and a.pattern == nil

  defp rows_of(visible, a) do
    rows = if grouped?(a), do: Group.group(visible), else: Enum.map(visible, &single/1)
    if a.view == :previous, do: Enum.map(rows, &%{&1 | id: "p-" <> &1.id}), else: rows
  end

  defp single(entry) do
    %{
      id: "e-#{entry.id}",
      key: nil,
      count: 1,
      entry: entry,
      ids: [entry.id],
      first_at: entry.at
    }
  end

  # The current row with id `row_id`, else the one holding entry `entry_id`
  # (after evictions a rendered row's id can be older than the rebuilt
  # row's), given `row_id` so it updates that DOM row.
  defp find_row(a, row_id, entry_id) do
    rows = a |> current() |> Enum.filter(&visible?(&1, a)) |> rows_of(a)
    id = parse_id(entry_id)

    cond do
      row = row_id && Enum.find(rows, &(&1.id == row_id)) -> row
      id == nil -> nil
      row = Enum.find(rows, &(id in &1.ids)) -> if(row_id, do: %{row | id: row_id}, else: row)
      true -> nil
    end
  end

  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_id(_id), do: nil

  # a stream item: the row plus what its markup shows. An expanded row's
  # lines come from its snapshot, so a batch that only joins it costs no
  # lookups or masking; `newer` counts the lines that joined since.
  defp item(row, a) do
    snap = if row.count > 1, do: expanded_snapshot(a, row)

    {lines, newer} =
      if snap,
        do: {snap.lines, Enum.count(Enum.take_while(row.ids, &(&1 > snap.newest)))},
        else: {[], 0}

    Map.merge(row, %{expanded?: snap != nil, lines: lines, newer: newer, open: a.open})
  end

  # The key of `row`'s snapshot in @expanded: its DOM id, else a snapshot
  # (of this view) whose newest entry the row holds.
  defp expanded_key(a, row) do
    if Map.has_key?(a.expanded, row.id) do
      row.id
    else
      Enum.find_value(a.expanded, fn {key, snap} ->
        if snap.view == a.view and snap.newest in row.ids, do: key
      end)
    end
  end

  defp expanded_snapshot(a, row) do
    case expanded_key(a, row) do
      nil -> nil
      key -> a.expanded[key]
    end
  end

  # the row's lines now, newest first, with their masked parts
  defp snapshot(a, row) do
    lines = for e <- lookup(current(a), row.ids), do: {e, Group.mask_spans(e.message)}
    %{view: a.view, newest: hd(row.ids), lines: lines}
  end

  defp lookup(entries, ids) do
    by_id = Map.new(entries, &{&1.id, &1})
    for id <- ids, e = by_id[id], do: e
  end

  defp toggle(set, value),
    do:
      if(MapSet.member?(set, value), do: MapSet.delete(set, value), else: MapSet.put(set, value))

  # oldest first
  defp export_entries(a, "all", _entry_id),
    do: a |> current() |> Enum.filter(&visible?(&1, a)) |> Enum.reverse()

  defp export_entries(a, row_id, entry_id) do
    case find_row(a, row_id, entry_id) do
      nil -> []
      row -> a |> current() |> lookup(row.ids) |> Enum.reverse()
    end
  end

  defp export_name(node) do
    node = if node, do: Atom.to_string(node), else: "beamdash"

    "#{node}-#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")}.log"
  end

  ## Tree

  # The Tree of the current view's lines that pass the level and text
  # filters (not a pattern or a tree scope: the tree is where those come
  # from). Only while the Tree tab shows.
  defp refresh_tree(%{assigns: %{tab: :tree} = a} = socket) do
    tree =
      Tree.build(filtered(a),
        apps: a.tree_apps,
        since: a.tree_since,
        template_cache: a.tree_cache,
        group_keys: a.tree_group_keys,
        hidden: a.tree_hidden
      )

    assign(socket, tree: tree, tree_cache: tree.template_cache)
  end

  # Crashes, the same way; then the node is asked for the supervisors of
  # the crashed names no line gave
  defp refresh_tree(%{assigns: %{tab: :crashes} = a} = socket) do
    result = Cascade.analyze(filtered(a), a.cascade_known, a.cascade_cache)
    socket = assign(socket, cascades: result.incidents, cascade_cache: result.cache)

    case {a.status, a.cascade_asking?, result.unknown} do
      {:connected, false, [_ | _] = names} ->
        {target, node} = {a.target, a.node}

        socket
        |> assign(cascade_asking?: true)
        |> start_async(:cascade_ancestors, fn ->
          {node, names, Target.process_ancestors(names, target)}
        end)

      _ ->
        socket
    end
  end

  defp refresh_tree(socket), do: socket

  defp filtered(a),
    do:
      Enum.filter(
        current(a),
        &(Filter.level_ok?(a.min_level, &1) and Filter.match?(a.filter, &1))
      )

  # new lines rebuild the Tree or Crashes at most every @tree_ms
  defp schedule_tree(%{assigns: %{tab: tab, tree_timer: nil}} = socket)
       when tab in [:tree, :crashes],
       do: assign(socket, tree_timer: Process.send_after(self(), :rebuild_tree, @tree_ms))

  defp schedule_tree(socket), do: socket

  # The node's module → application map, once per connection.
  defp load_tree_apps(%{assigns: %{status: :connected, node: node}} = socket) do
    if socket.assigns.tree_apps_node == node do
      socket
    else
      target = socket.assigns.target

      socket
      |> assign(tree_apps_error: nil)
      |> start_async(:tree_apps, fn -> {node, Target.module_apps(target)} end)
    end
  end

  defp load_tree_apps(socket), do: socket

  # Until a node is opened or closed, the first application is open.
  defp tree_open(%{tree_open: nil, tree: %{nodes: [first | _]}}), do: MapSet.new([first.id])
  defp tree_open(%{tree_open: nil}), do: MapSet.new()
  defp tree_open(%{tree_open: open}), do: open

  ## Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <main class="wrap" id="logs-page" phx-hook="LogExport">
      <BeamdashWeb.Layouts.header
        active={:logs}
        syntax={assigns[:syntax] || :erlang}
        conn={assigns[:conn]}
        ask={assigns[:ask]}
        ask_on={BeamdashWeb.JevSection.ask_on?(assigns[:jev_enabled])}
      />

      <p :if={@status != :connected and @total == 0 and @view == :live} class="help">
        Not connected: enter a node above and click Connect.
      </p>

      <BeamdashWeb.LogsTable.source_bar
        info={@info}
        node={@node}
        view={@view}
        connected?={@status == :connected}
        loading?={@source_loading?}
      />

      <p :if={@source_error} class="error" role="alert">{@source_error}</p>

      <div class="seg logs-tabs" role="tablist" aria-label="Logs view">
        <button
          :for={{value, label} <- [{"lines", "Lines"}, {"tree", "Tree"}, {"crashes", "Crashes"}]}
          type="button"
          role="tab"
          id={"logs-tab-#{value}"}
          class={["seg-btn", Atom.to_string(@tab) == value && "active"]}
          aria-selected={to_string(Atom.to_string(@tab) == value)}
          phx-click="tab"
          phx-value-tab={value}
        >
          {label}
        </button>
      </div>

      <div class="logs-controls">
        <form id="logs-level-form" phx-change="level">
          <select name="level" aria-label="Minimum level">
            <option
              :for={
                {value, label} <- [
                  {"", "all levels"},
                  {"debug", "debug"},
                  {"info", "info"},
                  {"notice", "notice"},
                  {"warning", "warning"},
                  {"error", "error and above"}
                ]
              }
              value={value}
              selected={value == level_value(@min_level)}
            >
              {label}
            </option>
          </select>
        </form>
        <form id="logs-filter-form" class="logs-filter" phx-change="filter" phx-submit="filter">
          <input
            id="logs-filter"
            type="search"
            name="q"
            value={@filter_text}
            phx-debounce="250"
            placeholder={~s(filter: words, -exclude, "exact phrase")}
            autocomplete="off"
            aria-label="Filter logs"
          />
        </form>
        <span :if={@pattern} class="chip">
          pattern: {elem(@pattern, 2)}
          <button
            type="button"
            phx-click="clear_pattern"
            aria-label="Remove pattern filter"
            title="Remove"
          >
            ✕
          </button>
        </span>
        <span :if={@scope} class="chip">
          {scope_label(@scope)}
          <button type="button" phx-click="clear_scope" aria-label="Remove tree filter" title="Remove">
            ✕
          </button>
        </span>
        <label
          :if={@tab == :lines}
          class="logs-check"
          title={@pattern && "Off while a pattern is set"}
        >
          <input
            type="checkbox"
            phx-click="toggle_group"
            checked={@group? and @pattern == nil}
            disabled={@pattern != nil}
          /> Group repeats
        </label>
        <div class="logs-pause-controls">
          <button
            :if={@view == :live and not @paused?}
            type="button"
            class="secondary"
            phx-click="pause"
          >
            Pause
          </button>
          <button :if={@view == :live and @paused?} type="button" phx-click="resume">
            Resume <span :if={@pending > 0}>+{@pending} new</span>
          </button>
          <div class="logs-scroll-controls" role="group" aria-label="Log navigation">
            <button id="logs-scroll-top" type="button" class="secondary">Jump to top</button>
            <button id="logs-scroll-bottom" type="button" class="secondary">Follow latest</button>
          </div>
        </div>
        <%= if @view == :live do %>
          <button type="button" class="secondary" phx-click="clear">Clear</button>
        <% end %>
        <button
          type="button"
          class="secondary"
          phx-click="export"
          phx-value-id="all"
          phx-value-mode="copy"
        >
          Copy all
        </button>
        <button
          type="button"
          class="secondary"
          phx-click="export"
          phx-value-id="all"
          phx-value-mode="download"
        >
          Download all
        </button>
        <button
          type="button"
          class="secondary"
          phx-click="toggle_app_levels"
          aria-expanded={to_string(@app_levels_open?)}
        >
          App levels
        </button>
        <span class="muted small">
          {@shown} of {@total} lines<span :if={@info.dropped > 0}>, {@info.dropped} dropped</span>
        </span>
        <span
          :if={@export_note}
          class={["logs-note small", elem(@export_note, 0) == :error && "error"]}
          role="status"
        >
          {elem(@export_note, 1)}
        </span>
      </div>

      <.app_levels
        :if={@app_levels_open?}
        levels={@app_levels}
        loading?={@app_levels_loading?}
        error={@app_levels_error}
        note={@app_level_note}
        source={@info.source}
      />

      <p :if={@view == :previous and @previous_loading?} class="muted">
        Loading previous container…
      </p>
      <p :if={@view == :previous and @previous_error} class="error">{@previous_error}</p>

      <p :if={@min_level && @no_level > 0} class="muted small">
        {@no_level} of {@total} lines have no level that could be read from their format, so a level filter hides them.
      </p>

      <p :if={filtering?(assigns) and @shown == 0 and @total > 0} class="help">
        No lines match the filter.
        <button type="button" class="secondary" phx-click="clear_filter">Clear filter</button>
      </p>

      <BeamdashWeb.LogsTable.table
        :if={@tab == :lines}
        rows={@streams.rows}
        filter={@filter}
        node={if @status == :connected, do: @node}
      />

      <.crashes :if={@tab == :crashes} incidents={@cascades} />

      <.tree
        :if={@tab == :tree}
        tree={@tree}
        open={tree_open(assigns)}
        detail={@tree_detail}
        group_keys={@tree_group_keys}
        checked={@tree_checked}
        hidden={@tree_hidden}
        apps_error={@tree_apps_error}
        since={@tree_since}
        source={@info.source}
      />
    </main>
    """
  end

  attr :levels, :map, required: true
  attr :loading?, :boolean, required: true
  attr :error, :string, required: true
  attr :note, :any, required: true
  attr :source, :atom, required: true

  defp app_levels(assigns) do
    assigns = assign(assigns, :choices, @app_levels)

    ~H"""
    <section id="logs-app-levels" class="logs-app-levels">
      <form
        :if={@levels}
        id="logs-primary-level"
        class="logs-primary-level"
        phx-change="set_primary_level"
      >
        <label>
          Primary level
          <select name="level" data-level={@levels.primary} aria-label="Primary log level">
            <option
              :for={choice <- tl(@choices)}
              value={choice}
              selected={choice == Atom.to_string(@levels.primary)}
            >
              {choice}
            </option>
          </select>
        </label>
      </form>
      <p class="muted small">
        Levels set here last on the node until it restarts. The primary level applies to every
        log call. An application's level applies to the ?LOG_* macros (Logger in Elixir) in its
        modules; plain <code>logger:debug(...)</code>
        calls, such as riak_core's, follow the primary level only, so lower the primary level
        to see them. Debug calls removed when the code was compiled can't be turned on.
        <span :if={@source == :kubectl}>
          kubectl logs shows what the node's console prints, so its handler level may still hide
          events.
        </span>
      </p>
      <p :if={@loading? and @levels == nil} class="muted">Loading application levels…</p>
      <p :if={@error} class="error">{@error}</p>
      <p
        :if={@note}
        class={["logs-note small", elem(@note, 0) == :error && "error"]}
        role="status"
      >
        {elem(@note, 1)}
      </p>
      <table :if={@levels} class="logs-app-levels-table">
        <thead>
          <tr>
            <th>Application</th><th>Level</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={{app, level} <- @levels.apps}>
            <td>{app}</td>
            <td>
              <form phx-change="set_app_level">
                <input type="hidden" name="app" value={app} />
                <select
                  name="level"
                  data-app={app}
                  data-level={level}
                  aria-label={"Log level of #{app}"}
                >
                  <option :if={level == :mixed} value="" selected disabled>
                    mixed (some modules)
                  </option>
                  <option
                    :for={choice <- @choices}
                    value={choice}
                    selected={choice == Atom.to_string(level)}
                  >
                    {choice}
                  </option>
                </select>
              </form>
            </td>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end

  attr :tree, :map, required: true
  attr :open, :any, required: true
  attr :apps_error, :string, required: true
  attr :since, :any, required: true
  attr :source, :atom, required: true
  attr :detail, :any, required: true
  attr :group_keys, :list, default: []
  attr :checked, :list, default: []
  attr :hidden, :list, default: []

  defp tree(assigns) do
    assigns =
      assign(assigns,
        rows: if(assigns.tree, do: Tree.rows(assigns.tree.nodes, assigns.open), else: [])
      )

    ~H"""
    <section id="logs-tree" class="logs-tree" role="tabpanel" aria-labelledby="logs-tab-tree">
      <div class="section-head">
        <span :if={@tree} class="muted small" role="status">
          {summary(@tree)}
          <span :if={@tree.window}>
            · {clock(elem(@tree.window, 0))}–{clock(elem(@tree.window, 1))} UTC
          </span><span :if={@tree.new > 0}> · <span class="badge badge-new">{@tree.new} new</span>
          since {clock(@since)}</span>
        </span>
        <span class="logs-tree-actions">
          <button type="button" class="secondary small-btn" phx-click="tree_expand_all">
            Expand all
          </button>
          <button type="button" class="secondary small-btn" phx-click="tree_collapse_all">
            Collapse all
          </button>
          <span :if={@group_keys != []} class="muted small">
            grouped by {Enum.join(@group_keys, ", ")}
          </span>
          <button
            :if={@group_keys != []}
            type="button"
            class="secondary small-btn"
            phx-click="tree_ungroup"
          >
            Ungroup
          </button>
          <button
            :if={@hidden != []}
            type="button"
            class="secondary small-btn"
            phx-click="tree_restore"
          >
            Restore {length(@hidden)} removed
          </button>
        </span>
      </div>
      <p class="muted small">
        The lines by where they came from: application, module, then each kind of line (the
        message with its numbers, ids and pids masked), with the most errors first. Click a row
        to open it, and <strong>Lines</strong>
        to see its lines. A line's level and the filter above apply here too.
        <span :if={@source == :kubectl}>
          Lines read from <code>kubectl logs</code>
          text name no module, so they are under <em>no source</em>.
        </span>
      </p>
      <p :if={@apps_error} class="error">{@apps_error}</p>
      <p :if={@tree && @tree.lines == 0} class="muted">No lines.</p>
      <table :if={@rows != []} class="logs-tree-table" aria-label="Log tree">
        <thead>
          <tr>
            <th>Source</th>
            <th class="num">Lines</th>
            <th class="num">Errors</th>
            <th class="num">Warnings</th>
            <th title="Lines over the time the buffer covers, oldest on the left">Activity</th>
            <th>Last</th>
            <th><span class="sr-only">Actions</span></th>
          </tr>
        </thead>
        <tbody>
          <%= for row <- @rows do %>
            <tr
              id={"tree-" <> row.node.id}
              class={[
                "logs-tree-row",
                "logs-tree-#{row.node.kind}",
                row.node.problems > 0 && "has-problems"
              ]}
            >
              <td style={"padding-left: #{0.5 + row.depth * 1.25}rem"}>
                <button
                  :if={row.node.children != []}
                  type="button"
                  class="tree-toggle"
                  phx-click="tree_toggle"
                  phx-value-id={row.node.id}
                  aria-expanded={to_string(row.open?)}
                >
                  <span aria-hidden="true">{if row.open?, do: "▾", else: "▸"}</span>
                  <span class={["tree-label", row.node.kind != :app && "mono"]}>{row.node.label}</span>
                </button>
                <button
                  :if={row.node.children == [] and row.node.kind == :template}
                  type="button"
                  class="tree-toggle"
                  phx-click="tree_detail"
                  phx-value-id={row.node.id}
                  aria-expanded={to_string(MapSet.member?(@detail, row.node.id))}
                  title="Show the key=value fields of this message"
                >
                  <span aria-hidden="true">
                    {if MapSet.member?(@detail, row.node.id), do: "▾", else: "▸"}
                  </span>
                  <span class="tree-label tree-leaf mono">{row.node.label}</span>
                </button>
                <span
                  :if={row.node.children == [] and row.node.kind != :template}
                  class="tree-label tree-leaf mono"
                >
                  {row.node.label}
                </span>
                <span :if={row.node.new > 0} class="badge badge-new">
                  {if row.node.kind == :template, do: "new", else: "#{row.node.new} new"}
                </span>
                <span :if={row.node.more > 0} class="muted small">
                  (showing {length(row.node.children)}, {row.node.more} more)
                </span>
              </td>
              <td class="num">{row.node.count}</td>
              <td class={["num", row.node.problems > 0 && "error"]}>{row.node.problems}</td>
              <td class={["num", row.node.warnings > 0 && "lvl-warning"]}>{row.node.warnings}</td>
              <td>
                <span class="spark mono" aria-hidden="true">{Tree.spark_text(row.node.spark)}</span>
              </td>
              <td class="small muted">{row.node.last_at && clock(row.node.last_at)}</td>
              <td>
                <button
                  type="button"
                  class="secondary small-btn"
                  phx-click="tree_show"
                  phx-value-id={row.node.id}
                  title="Show these lines on the Lines tab"
                >
                  Lines
                </button>
                <button
                  :if={row.node.kind == :field}
                  type="button"
                  class="secondary small-btn"
                  phx-click="tree_hide_branch"
                  phx-value-id={row.node.id}
                  title="Remove this branch from the tree"
                >
                  Remove
                </button>
              </td>
            </tr>
            <tr
              :if={row.node.kind == :template and MapSet.member?(@detail, row.node.id)}
              class="logs-tree-detail"
            >
              <td colspan="7" style={"padding-left: #{0.5 + (row.depth + 1) * 1.25}rem"}>
                <p class="muted small">Fields of the newest line in this kind of line</p>
                <table
                  :if={tree_fields(row.node.sample) != []}
                  class="logs-json"
                  aria-label="Fields of this message"
                >
                  <tbody>
                    <tr :for={{key, value} <- tree_fields(row.node.sample)}>
                      <th scope="row">
                        <label class="field-pick">
                          <input
                            type="checkbox"
                            checked={{key, value} in @checked}
                            phx-click="tree_check"
                            phx-value-key={key}
                            phx-value-val={value}
                          />
                          {key}
                        </label>
                      </th>
                      <td><pre>{value}</pre></td>
                    </tr>
                  </tbody>
                </table>
                <p :if={tree_fields(row.node.sample) == []} class="muted small">
                  No key=value fields in this line.
                </p>
                <div :if={tree_fields(row.node.sample) != []} class="tree-field-actions">
                  <button
                    type="button"
                    class="secondary small-btn"
                    phx-click="tree_filter"
                    disabled={@checked == []}
                  >
                    Filter by checked fields
                  </button>
                  <button
                    type="button"
                    class="small-btn"
                    phx-click="tree_regroup"
                    disabled={@checked == []}
                  >
                    Regroup by checked fields
                  </button>
                </div>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </section>
    """
  end

  defp tree_fields(%{message: message} = entry) do
    (Map.get(entry, :fields) || Pretty.all_fields(message))
    |> Enum.reject(fn {key, _value} -> key == "text" end)
  end

  defp tree_fields(_entry), do: []

  defp summary(tree) do
    Enum.join(
      [
        count(tree.lines, "line", "lines"),
        count(length(tree.nodes), "application", "applications"),
        count(tree.modules, "module", "modules"),
        count(tree.templates, "kind of line", "kinds of line")
      ],
      " · "
    )
  end

  attr :incidents, :list, required: true

  defp crashes(assigns) do
    assigns =
      assign(assigns,
        shown: Enum.take(assigns.incidents || [], 20),
        total: Enum.sum(Enum.map(assigns.incidents || [], & &1.crashes))
      )

    ~H"""
    <section id="logs-crashes" class="logs-tree" role="tabpanel" aria-labelledby="logs-tab-crashes">
      <p :if={@incidents} class="muted small" role="status">
        {count(length(@incidents), "incident", "incidents")} · {count(@total, "crash", "crashes")}<span :if={
          length(@incidents) > 20
        }> · the newest 20 shown</span>
      </p>
      <p class="muted small">
        The crashes in these lines, grouped into incidents (crashes less than 10 s apart), each
        drawn as the supervision chain it ran through: which processes crashed and how often,
        under which supervisor, which supervisor gave up and which application exited. Read from
        OTP's crash and supervisor reports and Elixir's "terminating" lines. Elixir's Logger drops
        supervisor reports unless <code>handle_sasl_reports</code>
        is set; the supervisors are then read from the node, for the processes running now.
      </p>
      <p :if={@incidents == []} class="muted">No crashes in these lines.</p>
      <article :for={inc <- @shown} id={"incident-" <> inc.id} class="insights-card cascade">
        <div class="section-head">
          <h3 class="cascade-title">
            {clock(inc.from)}<span :if={inc.to != inc.from}>–{clock(inc.to)}</span>
            UTC · {count(inc.crashes, "crash", "crashes")} of {count(
              inc.processes,
              "process",
              "processes"
            )}
          </h3>
          <button
            type="button"
            class="secondary small-btn"
            phx-click="crash_lines"
            phx-value-id={inc.id}
            title="The lines from 2 s before to 2 s after, on the Lines tab"
          >
            Lines
          </button>
        </div>
        <p :if={inc.gave_up != [] or inc.app_exits != []} class="cascade-outcome">
          <span :for={sup <- inc.gave_up} class="badge badge-gave-up">{sup} gave up</span>
          <span :for={{app, reason} <- inc.app_exits} class="badge badge-gave-up">
            application {app} exited: {reason}
          </span>
        </p>
        <ul class="cascade-chain">
          <li
            :for={row <- inc.rows}
            class={["cascade-node", row.node.crashes > 0 && "crashed"]}
            style={"padding-left: #{row.depth * 1.25}rem"}
          >
            <span :if={row.depth > 0} class="muted" aria-hidden="true">└</span>
            <span class={["mono", "cascade-name", row.node.supervisor? && "cascade-sup"]}>
              {row.node.name}
            </span>
            <span :if={row.node.supervisor?} class="muted small">supervisor</span>
            <span :if={row.node.gave_up} class="error small">gave up: {row.node.gave_up}</span>
            <span :if={row.node.crashes > 0} class="error small">
              {if row.node.supervisor?, do: "exited", else: "crashed"} {row.node.crashes}×<span :if={
                length(row.node.pids) > 1
              }> ({length(row.node.pids)} pids)</span>
            </span>
            <span :if={row.node.start_errors > 0} class="error small">
              failed to start {row.node.start_errors}×
            </span>
            <span
              :for={{reason, n} <- Enum.take(row.node.reasons, 3)}
              class="mono small cascade-reason"
            >
              {reason}<span :if={length(row.node.reasons) > 1} class="muted"> ×{n}</span>
            </span>
            <button
              :if={row.node.entry_ids != []}
              type="button"
              class="secondary small-btn"
              phx-click="crash_lines"
              phx-value-id={inc.id}
              phx-value-name={row.node.name}
              title="These lines on the Lines tab"
            >
              Lines
            </button>
          </li>
        </ul>
      </article>
    </section>
    """
  end

  defp count(1, one, _many), do: "1 #{one}"
  defp count(n, _one, many), do: "#{n} #{many}"

  defp clock(nil), do: ""
  defp clock(%DateTime{} = at), do: Calendar.strftime(at, "%H:%M:%S")

  defp level_value(nil), do: ""
  defp level_value(level), do: Atom.to_string(level)

  defp filtering?(a),
    do:
      String.trim(a.filter_text) != "" or a.min_level != nil or a.pattern != nil or
        a.scope != nil
end
