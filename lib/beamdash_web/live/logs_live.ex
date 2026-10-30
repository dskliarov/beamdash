defmodule BeamdashWeb.LogsLive do
  @moduledoc """
  The target's log lines (`Beamdash.Logs`), newest first, with a level and
  a text filter, repeated lines combined into one row (`Beamdash.Logs.Group`),
  a group's original lines on Expand, "Show all like this" (a pattern
  filter), and Copy / Download of the original lines (the `LogExport` hook).

  The rows are a LiveView stream (`:rows`, at most 1,000 rendered). Each
  item is a group row from `Group.group/1` or, with grouping off or a
  pattern set, a single-entry row `%{id: "e-<id>", ...}`; Previous container
  rows are prefixed `p-` so DOM ids never collide with the live ones. Any
  filter, pattern, grouping or view change rebuilds the stream; new lines
  are inserted at the top, a similar one joining the top row in place.

  A batch of new lines is folded into the rows first, then each new or
  changed row is inserted once. When lines leave the 2,000-line buffer the
  top row (`@top_row`) and the oldest rendered row (`@oldest_row`) drop
  their ids but keep their DOM ids (the oldest is sent again only when it
  lost lines), and rendered rows whose lines have all left are deleted
  (`@row_ends`: a rendered row's newest entry id to its DOM row id). A
  rendered row's id can then be older than the one `Group.group/1` gives,
  so row events also carry the row's newest entry id (`phx-value-entry`)
  and `find_row` falls back to it.

  An expanded group keeps the lines it was expanded with (`@expanded`: DOM
  row id to a snapshot of its lines, already masked, and its newest entry
  id then). Newer similar lines only change its header: the count, the
  newest text and a "+N newer" button, Refresh, which takes a new
  snapshot. A snapshot is also found by its newest entry id, so a row
  whose id changed (a rebuild after evictions) stays expanded.

  The page keeps the live entries it has shown (`@entries`, newest first)
  and the Previous container's separately (`@previous`). `mount` reads
  `session["logs_server"]` and `session["target"]` (tests) or uses
  `Beamdash.Logs` and `Beamdash.Target`.
  """
  use Phoenix.LiveView

  alias Beamdash.{Format, Logs, Target}
  alias Beamdash.Logs.{Filter, Group}

  @max_rows 1_000
  @max_entries 2_000
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
        top_row: nil,
        oldest_row: nil,
        row_ends: %{},
        export_note: nil,
        total: 0,
        shown: 0,
        no_level: 0,
        app_levels_open?: false,
        app_levels: nil,
        app_levels_loading?: false,
        app_levels_error: nil,
        app_level_note: nil
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

  defp event("clear_filter", _params, socket) do
    {:noreply,
     socket
     |> assign(filter_text: "", filter: Filter.parse(""), min_level: nil, pattern: nil)
     |> reset_rows()}
  end

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

  defp event("view", %{"view" => "live"}, socket) do
    {:noreply,
     socket
     |> assign(view: :live, previous: nil, previous_loading?: false, previous_error: nil)
     |> assign(open: MapSet.new())
     |> reset_rows()}
  end

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

  ## Background load of the Previous container

  @impl true
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
    socket = assign(socket, status: :connected, node: node, app_level_note: nil)
    {:noreply, if(socket.assigns.app_levels_open?, do: load_app_levels(socket), else: socket)}
  end

  def handle_info({:beamdash_target, {:disconnected, _}}, socket),
    do: {:noreply, assign(socket, status: :disconnected, app_levels: nil, app_level_note: nil)}

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
    socket = assign(socket, entries: [], expanded: %{}, open: MapSet.new())
    if socket.assigns.view == :live, do: reset_rows(socket), else: socket
  end

  # Newer entries (newest first) on top of the live ones.
  defp add_entries(socket, batch) do
    a = socket.assigns
    all = batch ++ a.entries
    entries = Enum.take(all, @max_entries)
    socket = assign(socket, entries: entries, newest_id: max(a.newest_id, hd(batch).id))

    if a.view == :live do
      evicted = Enum.drop(all, @max_entries)
      new = batch |> Enum.reverse() |> Enum.filter(&visible?(&1, a))
      shown = a.shown + length(new) - Enum.count(evicted, &visible?(&1, a))

      socket
      |> assign(total: length(entries), shown: shown)
      |> insert_rows(new, evicted)
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
    old = if grouped?(a), do: List.wrap(a.top_row), else: []

    # newest first, ending with the old top row when there is one
    rows =
      if grouped?(a),
        do: Enum.reduce(new, old, &Group.add(&2, &1)),
        else: new |> Enum.map(&single/1) |> Enum.reverse()

    kept = rows |> Enum.map(&trim(&1, gone, a.entries)) |> Enum.reject(&(&1.ids == []))
    changed = Enum.reject(kept, &(&1 in old))

    # a rendered row is gone once its newest entry is (lines leave oldest first)
    ends = Map.drop(a.row_ends, Enum.map(old, & &1.entry.id))
    {gone_rows, ends} = Map.split(ends, Enum.map(evicted, & &1.id))
    ends = Enum.reduce(kept, ends, &Map.put(&2, &1.entry.id, &1.id))
    kept_ids = MapSet.new(kept, & &1.id)

    deleted =
      (Map.values(gone_rows) ++ Enum.map(old, & &1.id))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(kept_ids, &1))

    socket = assign(socket, top_row: if(grouped?(a), do: List.first(kept)), row_ends: ends)
    socket = Enum.reduce(deleted, socket, &stream_delete_by_dom_id(&2, :rows, "rows-" <> &1))

    socket =
      changed
      |> Enum.reverse()
      |> Enum.reduce(socket, &stream_insert(&2, :rows, item(&1, a), at: 0, limit: @max_rows))

    socket =
      if grouped?(a), do: update_oldest(socket, List.first(old), kept, gone), else: socket

    if deleted == [], do: socket, else: prune_expanded(socket)
  end

  # Drops the snapshots (up to 2,000 lines each) of rows that are no longer
  # rendered: no row_ends value is their key, and they are not the top or
  # the oldest row.
  defp prune_expanded(%{assigns: %{expanded: expanded}} = socket) when expanded == %{}, do: socket

  defp prune_expanded(%{assigns: a} = socket) do
    live = MapSet.new(Map.values(a.row_ends))

    live =
      Enum.reduce([a.top_row, a.oldest_row], live, &if(&1, do: MapSet.put(&2, &1.id), else: &2))

    assign(socket, expanded: Map.filter(a.expanded, fn {key, _} -> MapSet.member?(live, key) end))
  end

  # Keeps @oldest_row, the oldest rendered row, in step: the old top row's
  # new version when that was it, the batch's oldest row when there was
  # none. Else it is trimmed by set lookups and sent again only when it
  # lost lines; once all its lines are gone (it was deleted) the next
  # oldest is rebuilt from the entries.
  defp update_oldest(socket, old_top, kept, gone) do
    a = socket.assigns
    oldest = a.oldest_row

    cond do
      oldest == nil ->
        assign(socket, oldest_row: List.last(kept))

      old_top != nil and oldest.id == old_top.id ->
        assign(socket, oldest_row: Enum.find(kept, &(&1.id == oldest.id)) || List.last(kept))

      true ->
        case trim(oldest, gone, a.entries) do
          ^oldest -> socket
          %{ids: []} -> next_oldest(socket, kept)
          trimmed -> socket |> assign(oldest_row: trimmed) |> update_row(trimmed)
        end
    end
  end

  defp next_oldest(%{assigns: a} = socket, kept) do
    case rebuild_oldest(a) do
      nil ->
        assign(socket, oldest_row: nil)

      row ->
        case Enum.find(kept, &(&1.id == row.id)) do
          nil -> socket |> assign(oldest_row: row) |> update_row(row)
          kept_row -> assign(socket, oldest_row: kept_row)
        end
    end
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

  # The oldest rendered row, from the entries: the visible entries up to
  # the oldest rendered row's newest one, as far back as they stay similar
  # (rows past the 1,000 rendered ones can come before it). Only after the
  # row before it went, so the masking here is once per row.
  defp rebuild_oldest(a) do
    {run, rest} =
      a.entries
      |> Enum.reverse()
      |> Enum.filter(&visible?(&1, a))
      |> Enum.split_while(&(not Map.has_key?(a.row_ends, &1.id)))

    case rest do
      [newest | _] ->
        key = Group.key(newest)

        group =
          run |> Enum.reverse() |> Enum.take_while(&(Group.key(&1) == key)) |> Enum.reverse()

        group = group ++ [newest]

        %{
          id: a.row_ends[newest.id],
          key: key,
          count: length(group),
          entry: newest,
          first_at: hd(group).at,
          ids: group |> Enum.map(& &1.id) |> Enum.reverse()
        }

      [] ->
        nil
    end
  end

  # Rebuilds the stream from the current view's entries.
  defp reset_rows(socket) do
    a = socket.assigns
    entries = current(a)
    visible = Enum.filter(entries, &visible?(&1, a))
    rows = rows_of(visible, a)
    rendered = Enum.take(rows, @max_rows)
    live_grouped? = grouped?(a) and a.view == :live
    top = if live_grouped?, do: List.first(rows)
    oldest = if live_grouped?, do: List.last(rendered)
    ends = if a.view == :live, do: Map.new(rendered, &{&1.entry.id, &1.id}), else: %{}
    # everything is rendered again: expanded rows show all their lines
    a = %{a | expanded: resnapshot(a, rendered)}

    socket
    |> assign(
      total: length(entries),
      shown: length(visible),
      # lines whose format gave no level: a level filter hides them all
      no_level: if(a.min_level, do: Enum.count(entries, &(&1.level == nil)), else: 0),
      top_row: top,
      oldest_row: oldest,
      row_ends: ends,
      expanded: a.expanded
    )
    |> stream(:rows, Enum.map(rendered, &item(&1, a)), reset: true)
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
      (a.pattern == nil or Group.key(entry) == a.pattern)
  end

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

      <BeamdashWeb.LogsTable.source_bar info={@info} node={@node} view={@view} />

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
        <label class="logs-check" title={@pattern && "Off while a pattern is set"}>
          <input
            type="checkbox"
            phx-click="toggle_group"
            checked={@group? and @pattern == nil}
            disabled={@pattern != nil}
          /> Group repeats
        </label>
        <%= if @view == :live do %>
          <button :if={not @paused?} type="button" class="secondary" phx-click="pause">
            Pause
          </button>
          <button :if={@paused?} type="button" phx-click="resume">
            Resume <span :if={@pending > 0}>+{@pending} new</span>
          </button>
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
        rows={@streams.rows}
        filter={@filter}
        node={if @status == :connected, do: @node}
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
          <select name="level" aria-label="Primary log level">
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
                <select name="level" data-app={app} aria-label={"Log level of #{app}"}>
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

  defp level_value(nil), do: ""
  defp level_value(level), do: Atom.to_string(level)

  defp filtering?(a),
    do: String.trim(a.filter_text) != "" or a.min_level != nil or a.pattern != nil
end
