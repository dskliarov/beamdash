defmodule BeamdashWeb.SnapshotsLive do
  @moduledoc """
  Snapshots tab: the process snapshots `Beamdash.Sampler` keeps in
  `Beamdash.Store`. Each sample is one snapshot, listed by its time, newest
  first. Selecting one shows its processes grouped by reason. Filter by time
  window, reason and pid. The processes that stood out most across the window
  are listed as suspects, and marked in each snapshot (`Beamdash.Insights.Suspects`).
  """
  use Phoenix.LiveView

  alias Beamdash.{Format, Settings, Store}
  alias Beamdash.Insights.Suspects

  @windows [
    {"15 min", 900},
    {"1 hour", 3_600},
    {"6 hours", 21_600},
    {"24 hours", 86_400},
    {"7 days", 604_800}
  ]
  @reasons [
    {"all", "All reasons"},
    {"load", "Busiest"},
    {"memory", "Most memory"},
    {"heap_rising", "Heap rising"}
  ]
  @page 100
  @max_limit 1_000
  @max_detail 1_000
  @memory_points 240
  @suspect_rows 1_000
  @refresh_ms 10_000

  @impl true
  def mount(_params, _session, socket) do
    if Settings.snapshots_enabled?() do
      socket =
        assign(socket,
          window: 3_600,
          reason: "all",
          pid: "",
          limit: @page,
          snapshots: [],
          selected: nil,
          detail: [],
          memory: [],
          suspect_key: nil,
          suspects: Suspects.analyze([]),
          expanded: MapSet.new(),
          enabled: Process.whereis(Store) != nil
        )

      if connected?(socket), do: send(self(), :tick)

      {:ok, load(socket)}
    else
      {:ok, redirect(socket, to: "/")}
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    socket =
      assign(socket,
        window: window(params["window"]),
        reason: reason(params["reason"]),
        pid: String.trim(params["pid"] || ""),
        limit: @page,
        selected: nil,
        expanded: MapSet.new()
      )

    {:noreply, load(socket)}
  end

  def handle_event("more", _, socket) do
    {:noreply, socket |> update(:limit, &min(&1 + @page, @max_limit)) |> load()}
  end

  def handle_event("select", %{"at" => at}, socket),
    do:
      {:noreply,
       socket |> assign(selected: String.to_integer(at), expanded: MapSet.new()) |> load()}

  def handle_event("toggle_details", %{"pid" => pid}, socket) do
    expanded = socket.assigns.expanded

    expanded =
      if MapSet.member?(expanded, pid),
        do: MapSet.delete(expanded, pid),
        else: MapSet.put(expanded, pid)

    {:noreply, assign(socket, expanded: expanded)}
  end

  @impl true
  def handle_info(:tick, socket) do
    if Settings.snapshots_enabled?() do
      Process.send_after(self(), :tick, @refresh_ms)
      {:noreply, load(socket)}
    else
      {:noreply, redirect(socket, to: "/")}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        windows: @windows,
        reasons: @reasons,
        max_limit: @max_limit,
        days: Store.policy().snapshots.max_age_days,
        node_memory: memory_view(assigns.memory)
      )

    ~H"""
    <main class="wrap">
      <BeamdashWeb.Layouts.header
        active={:snapshots}
        syntax={@syntax}
        conn={assigns[:conn]}
        ask={assigns[:ask]}
        ask_on={BeamdashWeb.JevSection.ask_on?(assigns[:jev_enabled])}
      />

      <section class="insights-card" aria-labelledby="snapshots-heading">
        <div class="section-head">
          <h3 id="snapshots-heading">Snapshots</h3>
          <span class="muted small" role="status">
            {Format.number(length(@snapshots))} shown · window {window_label(@window)}
          </span>
        </div>
        <p class="muted small">
          While connected, the node is sampled every 30 seconds. Each snapshot is one sample:
          the busiest processes, the ones using the most memory, and those whose memory rose
          at each of the last five samples. Select a snapshot to see its processes, grouped by
          reason. Snapshots are kept for {@days} days, then purged.
        </p>
        <p :if={!@enabled} class="error" role="alert">
          Snapshots are off: the event store is not running.
        </p>

        <form phx-change="filter" class="inline-form">
          <label for="snap-window" class="small muted">Window</label>
          <select id="snap-window" name="window">
            <option :for={{label, secs} <- @windows} value={secs} selected={secs == @window}>
              {label}
            </option>
          </select>
          <label for="snap-reason" class="small muted">Reason</label>
          <select id="snap-reason" name="reason">
            <option :for={{value, label} <- @reasons} value={value} selected={value == @reason}>
              {label}
            </option>
          </select>
          <label for="snap-pid" class="small muted">Pid</label>
          <input
            id="snap-pid"
            name="pid"
            type="text"
            value={@pid}
            placeholder="#PID&lt;0.123.0&gt;"
            phx-debounce="300"
          />
        </form>

        <.suspect_table :if={@enabled and @suspects.suspects != []} suspects={@suspects} />

        <.node_memory :if={@enabled and @node_memory} memory={@node_memory} />

        <p :if={@enabled and @snapshots == []} class="muted">
          No snapshots in this window yet.
        </p>

        <div :if={@snapshots != []} class="snapshots-split">
          <div class="snapshots-list">
            <div class="snapshots-list-body">
              <table class="insights-table">
                <thead>
                  <tr>
                    <th>Snapshot (UTC)</th>
                    <th class="num">Processes</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={snapshot <- @snapshots} class={snapshot.at == @selected && "active"}>
                    <td class="mono small">
                      <button
                        type="button"
                        class="small-btn"
                        phx-click="select"
                        phx-value-at={snapshot.at}
                        aria-pressed={to_string(snapshot.at == @selected)}
                      >
                        {time(snapshot.at)}
                      </button>
                    </td>
                    <td class="num">{Format.number(snapshot.count)}</td>
                  </tr>
                </tbody>
              </table>
              <button
                :if={length(@snapshots) == @limit and @limit < @max_limit}
                type="button"
                class="small-btn"
                phx-click="more"
              >
                Show more
              </button>
            </div>
          </div>

          <div class="snapshot-detail">
            <h4>
              Snapshot at {time(@selected)} UTC · {Format.number(length(@detail))} processes
            </h4>
            <p :if={@detail == []} class="muted small">
              No rows left for this snapshot. It may have been purged or filtered out.
            </p>
            <section :for={{label, rows} <- reason_groups(@detail)} class="snapshot-reason">
              <h5>{label} · {Format.number(length(rows))}</h5>
              <table class="insights-table">
                <.reason_columns />
                <thead>
                  <tr>
                    <th>Process</th>
                    <th class="num">Memory</th>
                    <th class="num">Queue</th>
                    <th class="num">Reductions/s</th>
                    <th>Status</th>
                    <th>Details</th>
                  </tr>
                </thead>
                <tbody :for={row <- rows}>
                  <tr>
                    <td>
                      {process_name(row)}
                      <span :if={suspect?(@suspects, row)} class="badge badge-suspect">Suspect</span>
                      <div class="muted small mono">
                        <.link navigate={process_link(row.pid)}>{row.pid}</.link>
                      </div>
                    </td>
                    <td class="num mono">{bytes(process(row, "memory"))}</td>
                    <td class="num">{number(process(row, "message_queue_len"))}</td>
                    <td class="num">{number(row.data["rate"])}</td>
                    <td class="small">{process(row, "status")}</td>
                    <td class="small">
                      <button
                        :if={row.data["details"]}
                        type="button"
                        class="small-btn"
                        phx-click="toggle_details"
                        phx-value-pid={row.pid}
                        aria-expanded={to_string(MapSet.member?(@expanded, row.pid))}
                      >
                        {if MapSet.member?(@expanded, row.pid), do: "Hide", else: "Show"}
                      </button>
                      <span :if={!row.data["details"]} class="muted">–</span>
                    </td>
                  </tr>
                  <tr :if={row.data["details"] && MapSet.member?(@expanded, row.pid)}>
                    <td colspan="6">
                      <.process_facts details={row.data["details"]} />
                    </td>
                  </tr>
                </tbody>
              </table>
            </section>
          </div>
        </div>
      </section>
    </main>
    """
  end

  defp load(%{assigns: %{enabled: false}} = socket),
    do:
      assign(socket,
        snapshots: [],
        detail: [],
        memory: [],
        suspect_key: nil,
        suspects: Suspects.analyze([])
      )

  defp load(socket) do
    %{window: window, limit: limit, selected: selected} = socket.assigns
    from = System.system_time(:millisecond) - window * 1_000
    filters = filters(socket)

    snapshots = Store.times(:snapshots, [from: from, limit: limit] ++ filters)
    selected = if selected && selected >= from, do: selected, else: latest(snapshots)

    detail =
      if selected,
        do:
          Store.query(
            :snapshots,
            [from: selected, to: selected, limit: @max_detail] ++ filters
          ),
        else: []

    memory = Store.query(:memory, from: from, limit: @memory_points)
    {suspect_key, suspects} = suspects(socket, from)

    assign(socket,
      snapshots: snapshots,
      selected: selected,
      detail: detail,
      memory: memory,
      suspect_key: suspect_key,
      suspects: suspects
    )
  end

  # The marks ignore the filters, so they are recomputed only when the window
  # or its newest snapshot changes, not on every refresh.
  defp suspects(socket, from) do
    key = {socket.assigns.window, latest(Store.times(:snapshots, from: from, limit: 1))}

    if key == socket.assigns.suspect_key,
      do: {key, socket.assigns.suspects},
      else: {key, Suspects.analyze(Store.query(:snapshots, from: from, limit: @suspect_rows))}
  end

  defp suspect?(%{flagged: flagged}, row), do: Map.has_key?(flagged, {row.at, row.pid})

  defp feature_label(:memory), do: "Memory"
  defp feature_label(:queue), do: "Mailbox"
  defp feature_label(:rate), do: "Reductions/s"

  defp suspect_table(assigns) do
    ~H"""
    <div class="snapshot-suspects">
      <h4>Suspected processes · {Format.number(@suspects.rows)} rows compared</h4>
      <p class="muted small">
        Processes that stood out from their peers in memory, mailbox length or reductions
        rate, across the newest snapshots of the window. Ranked by how many snapshots they
        stood out in. Their rows are marked Suspect in each snapshot.
      </p>
      <table class="insights-table">
        <thead>
          <tr>
            <th>Process</th>
            <th class="num">Snapshots</th>
            <th>Worst in</th>
            <th class="num">Score</th>
            <th class="num">Memory</th>
            <th class="num">Queue</th>
            <th class="num">Reductions/s</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={s <- @suspects.suspects}>
            <td>
              {s.name || "unnamed"}
              <div class="muted small mono">
                <.link navigate={process_link(s.pid)}>{s.pid}</.link>
              </div>
            </td>
            <td class="num">{Format.number(s.snapshots)}</td>
            <td>{feature_label(s.feature)}</td>
            <td class="num">{s.score}</td>
            <td class="num mono">{bytes(s.memory)}</td>
            <td class="num">{number(s.queue)}</td>
            <td class="num">{number(s.rate)}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # the newest memory sample against the oldest one in the window
  defp memory_view([]), do: nil

  defp memory_view([latest | _] = samples) do
    oldest = List.last(samples)

    %{
      at: latest.at,
      since: oldest.at,
      rows: node_memory_rows(latest.data, oldest.data),
      tables: table_rows(latest.data, oldest.data)
    }
  end

  defp node_memory_rows(now, before) do
    measures = [
      {"Total", ["memory", "total"], &bytes/1},
      {"Processes", ["memory", "processes"], &bytes/1},
      {"System", ["memory", "system"], &bytes/1},
      {"Binaries", ["memory", "binary"], &bytes/1},
      {"ETS", ["memory", "ets"], &bytes/1},
      {"Atoms", ["atom_count"], &number/1},
      {"ETS tables", ["ets_count"], &number/1}
    ]

    for {label, path, format} <- measures do
      value = get_in(now, path)
      {label, format.(value), change(value, get_in(before, path), format)}
    end
  end

  defp table_rows(now, before) do
    previous = Map.new(before["tables"] || [], &{table_key(&1), &1})

    for table <- now["tables"] || [] do
      change =
        case previous[table_key(table)] do
          nil -> "new"
          old -> change(table["memory"], old["memory"], &bytes/1)
        end

      Map.put(table, "change", change)
    end
  end

  defp table_key(table), do: {table["name"], table["owner"]}

  defp change(now, before, format) when is_integer(now) and is_integer(before) do
    case now - before do
      0 -> "no change"
      diff when diff > 0 -> "+" <> format.(diff)
      diff -> "-" <> format.(-diff)
    end
  end

  defp change(_now, _before, _format), do: "–"

  defp latest([%{at: at} | _]), do: at
  defp latest([]), do: nil

  defp filters(%{assigns: %{reason: reason, pid: pid}}) do
    filters = if reason == "all", do: [], else: [reason: reason]
    if pid == "", do: filters, else: [{:pid, pid} | filters]
  end

  # the rows of one snapshot, per reason, each sorted by the measure that made it appear
  defp reason_groups(rows) do
    @reasons
    |> Enum.reject(fn {value, _} -> value == "all" end)
    |> Enum.map(fn {value, label} ->
      {label, rows |> Enum.filter(&(&1.reason == value)) |> sort_for(value)}
    end)
    |> Enum.reject(fn {_, rows} -> rows == [] end)
  end

  defp sort_for(rows, "load"), do: Enum.sort_by(rows, &(&1.data["rate"] || 0), :desc)
  defp sort_for(rows, _reason), do: Enum.sort_by(rows, &(process(&1, "memory") || 0), :desc)

  defp window(value),
    do: Enum.find_value(@windows, 3_600, fn {_, s} -> if Integer.to_string(s) == value, do: s end)

  defp reason(value), do: if(List.keymember?(@reasons, value, 0), do: value, else: "all")

  defp window_label(window),
    do: Enum.find_value(@windows, fn {label, s} -> if s == window, do: label end)

  # one column layout for every reason table, so the columns line up
  defp reason_columns(assigns) do
    ~H"""
    <colgroup>
      <col style="width: 34%" />
      <col style="width: 12%" />
      <col style="width: 10%" />
      <col style="width: 14%" />
      <col style="width: 12%" />
      <col style="width: 18%" />
    </colgroup>
    """
  end

  defp node_memory(assigns) do
    ~H"""
    <div class="snapshot-memory">
      <h4>Node memory · {time(@memory.at)} UTC</h4>
      <p class="muted small">
        Changes are against {time(@memory.since)} UTC, the oldest sample shown. Tables are the
        largest ten in each sample; "new" means the table was not among the largest ten then.
      </p>
      <table class="insights-table">
        <thead>
          <tr>
            <th>Measure</th>
            <th class="num">Now</th>
            <th class="num">Change</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={{label, now, change} <- @memory.rows}>
            <td>{label}</td>
            <td class="num mono">{now}</td>
            <td class="num">{change}</td>
          </tr>
        </tbody>
      </table>

      <h5>Largest ETS tables</h5>
      <table class="insights-table">
        <thead>
          <tr>
            <th>Table</th>
            <th>Owner</th>
            <th class="num">Rows</th>
            <th class="num">Memory</th>
            <th class="num">Change</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={table <- @memory.tables}>
            <td class="mono small">{table["name"] || "–"}</td>
            <td class="mono small">{table["owner"] || "–"}</td>
            <td class="num">{number(table["size"])}</td>
            <td class="num mono">{bytes(table["memory"])}</td>
            <td class="num">{table["change"]}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp process_facts(assigns) do
    ~H"""
    <div class="snapshot-facts">
      <dl class="facts">
        <dt>Status</dt>
        <dd>{text(@details["status"])}</dd>
        <dt>Priority</dt>
        <dd>{text(@details["priority"])}{if @details["trap_exit"], do: " · traps exits"}</dd>
        <dt>Current function</dt>
        <dd class="mono">{text(@details["current_function"])}</dd>
        <dt>Reductions</dt>
        <dd>{number(@details["reductions"])}</dd>
        <dt>Links</dt>
        <dd>{count(@details["links"])}</dd>
        <dt>Monitors</dt>
        <dd>{count(@details["monitors"])} · monitored by {count(@details["monitored_by"])}</dd>
      </dl>

      <h5>Memory</h5>
      <table class="kv">
        <tr :for={{label, value} <- memory_rows(@details)}>
          <th>{label}</th>
          <td>{value}</td>
        </tr>
      </table>

      <h5>Garbage collection</h5>
      <table class="kv">
        <tr :for={{label, value} <- gc_rows(@details)}>
          <th>{label}</th>
          <td>{value}</td>
        </tr>
      </table>

      <h5>Mailbox · {number(@details["mailbox"]["length"])} messages</h5>
      <p :if={!is_list(@details["mailbox"]["messages"])} class="muted small">
        Not fetched: the mailbox was too long to copy.
      </p>

      <h5 :if={is_list(@details["current_stacktrace"]) and @details["current_stacktrace"] != []}>
        Current stack
      </h5>
      <pre
        :if={is_list(@details["current_stacktrace"]) and @details["current_stacktrace"] != []}
        class="small"
      >{Enum.map_join(@details["current_stacktrace"], "\n", &text/1)}</pre>
    </div>
    """
  end

  defp memory_rows(details) do
    memory = details["memory"] || %{}

    [
      {"Total", bytes(memory["total"])},
      {"Heap", bytes(memory["heap"])},
      {"Total heap", bytes(memory["total_heap"])},
      {"Stack", bytes(memory["stack"])},
      {"Off-heap binaries",
       "#{bytes(memory["binary_bytes"])} in #{number(memory["binary_count"])}"},
      {"Message queue data", text(memory["message_queue_data"])}
    ]
  end

  defp gc_rows(details) do
    gc = details["gc"] || %{}

    [
      {"Minor GCs", number(gc["minor_gcs"])},
      {"Full sweep after", number(gc["fullsweep_after"])},
      {"Old heap", bytes(gc["old_heap_size"])},
      {"Min heap", bytes(gc["min_heap_size"])},
      {"Max heap", bytes(gc["max_heap_size"])},
      {"Off-heap binary heap", bytes(gc["bin_vheap_size"])}
    ]
  end

  defp count(list) when is_list(list), do: Format.number(length(list))
  defp count(_), do: "–"

  defp text(value) when is_binary(value), do: value
  defp text(nil), do: "–"
  defp text(value), do: inspect(value)

  defp process_link(pid),
    do: "/?" <> URI.encode_query(%{"pid" => String.replace_prefix(pid, "#PID", "")})

  defp process(row, key), do: get_in(row.data, ["process", key])

  defp process_name(row),
    do: process(row, "name") || process(row, "initial_call") || "unnamed"

  defp time(ms),
    do: ms |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%Y-%m-%d %H:%M:%S")

  defp bytes(n) when is_integer(n), do: Format.bytes(n)
  defp bytes(_), do: "–"

  defp number(n) when is_integer(n), do: Format.number(n)
  defp number(_), do: "–"
end
