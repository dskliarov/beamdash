defmodule BeamdashWeb.CompareLive do
  @moduledoc """
  The processes and memory of up to three connected nodes, one column each.
  Which nodes are compared, the metric they are compared by, and each
  column's sort live in the socket only. Each checked column is read on the
  same tick as the other pages. A node that disconnects keeps its column,
  greyed out, until it is unchecked.
  """
  use Phoenix.LiveView

  alias Beamdash.{Format, Memory, Target}

  @refresh_ms 2_000
  @max_nodes 3
  @row_limit 100
  @default_column %{
    procs: nil,
    memory: nil,
    raw_memory: nil,
    error: nil,
    sort: {:name, :asc},
    last: nil
  }
  @metrics [
    message_queue_len: "Msg queue",
    reductions: "Reductions",
    memory: "Memory",
    heap_size: "Heap size",
    reductions_per_sec: "Reductions/s",
    ets: "ETS tables size",
    binary: "Binary size"
  ]
  @node_metrics [:ets, :binary]
  @metric_keys Map.new(@metrics, fn {key, _label} -> {Atom.to_string(key), key} end)
  @sort_cols %{"name" => :name, "metric" => :metric}

  @impl true
  def mount(_params, _session, socket) do
    if length(socket.assigns.conn.connections) < 2 do
      {:ok, push_navigate(socket, to: "/system")}
    else
      {:ok, start_compare(socket)}
    end
  end

  defp start_compare(socket) do
    checked =
      socket.assigns.conn.connections
      |> Enum.filter(&(&1.status == :connected))
      |> Enum.take(@max_nodes)
      |> Enum.map(& &1.server)

    socket =
      assign(socket,
        checked: checked,
        columns: %{},
        in_flight: MapSet.new(),
        filter: "",
        metric: :memory
      )

    if connected?(socket), do: send(self(), :compare_tick)
    socket
  end

  @impl true
  def handle_info(:compare_tick, socket) do
    Process.send_after(self(), :compare_tick, @refresh_ms)
    {:noreply, refresh(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_async({:compare, server}, result, socket) do
    socket = assign(socket, in_flight: MapSet.delete(socket.assigns.in_flight, server))

    if server in socket.assigns.checked,
      do: {:noreply, put_read(socket, server, result)},
      else: {:noreply, socket}
  end

  @impl true
  def handle_event("toggle", %{"node" => name}, socket) do
    case find_entry(socket, name) do
      nil -> {:noreply, socket}
      entry -> {:noreply, socket |> toggle(entry.server) |> refresh()}
    end
  end

  def handle_event("filter", %{"filter" => filter}, socket),
    do: {:noreply, assign(socket, filter: filter)}

  def handle_event("metric", %{"metric" => name}, socket) do
    case Map.fetch(@metric_keys, name) do
      {:ok, metric} -> {:noreply, assign(socket, metric: metric)}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("sort", %{"node" => name, "col" => col}, socket) do
    case {find_entry(socket, name), Map.fetch(@sort_cols, col)} do
      {%{server: server}, {:ok, by}} ->
        column = Map.get(socket.assigns.columns, server, @default_column)
        {:noreply, put_column(socket, server, sort: next_sort(column.sort, by))}

      _ ->
        {:noreply, socket}
    end
  end

  defp next_sort({by, :desc}, by), do: {by, :asc}
  defp next_sort({by, :asc}, by), do: {by, :desc}
  defp next_sort(_sort, :name), do: {:name, :asc}
  defp next_sort(_sort, by), do: {by, :desc}

  defp find_entry(socket, name),
    do: Enum.find(socket.assigns.conn.connections, &(Atom.to_string(&1.node) == name))

  defp toggle(socket, server) do
    checked = socket.assigns.checked

    cond do
      server in checked ->
        assign(socket,
          checked: List.delete(checked, server),
          columns: Map.delete(socket.assigns.columns, server)
        )

      length(checked) >= @max_nodes ->
        socket

      true ->
        assign(socket, checked: checked ++ [server])
    end
  end

  defp refresh(socket) do
    entries = socket.assigns.conn.connections
    checked = Enum.filter(socket.assigns.checked, &Enum.any?(entries, fn e -> e.server == &1 end))

    socket =
      assign(socket,
        checked: checked,
        columns: Map.take(socket.assigns.columns, checked)
      )

    if length(entries) < 2 do
      socket
    else
      Enum.reduce(checked, socket, fn server, acc ->
        case Enum.find(entries, &(&1.server == server)) do
          %{status: :connected, node: node} -> read(acc, server, node)
          _ -> acc
        end
      end)
    end
  end

  defp connected_count(connections), do: Enum.count(connections, &(&1.status == :connected))

  # Each read runs in a task, so a slow node never holds up the others; a
  # read still running is not started again.
  defp read(socket, server, node) do
    if MapSet.member?(socket.assigns.in_flight, server) do
      socket
    else
      bytes? = socket.assigns.metric in [:ets, :binary]

      socket
      |> assign(in_flight: MapSet.put(socket.assigns.in_flight, server))
      |> start_async({:compare, server}, fn ->
        {Target.process_list(server, bytes?), Memory.snapshot(node)}
      end)
    end
  end

  defp put_read(socket, server, {:ok, {{:ok, {procs, _info}}, {:ok, snap}}}) do
    now = System.monotonic_time(:millisecond)
    column = Map.get(socket.assigns.columns, server, @default_column)
    procs = with_rate(procs, column.last, now)

    put_column(socket, server,
      procs: procs,
      memory: memory(snap.memory),
      raw_memory: snap.memory,
      error: nil,
      last: {now, Map.new(procs, &{&1.pid, &1.reductions})}
    )
  end

  defp put_read(socket, server, {:ok, {{:error, reason}, _memory}}),
    do: put_column(socket, server, error: Format.error(reason))

  defp put_read(socket, server, {:ok, {_procs, {:error, reason}}}),
    do: put_column(socket, server, error: Format.error(reason))

  defp put_read(socket, server, _exit),
    do: put_column(socket, server, error: "The read failed. It is tried again on the next tick.")

  # Reductions per second since this node's previous read; nil on the first one.
  defp with_rate(procs, nil, _now), do: Enum.map(procs, &Map.put(&1, :reductions_per_sec, nil))

  defp with_rate(procs, {then, before}, now) do
    seconds = max(now - then, 1) / 1000

    Enum.map(procs, fn proc ->
      rate =
        case Map.fetch(before, proc.pid) do
          {:ok, reductions} -> (proc.reductions - reductions) / seconds
          :error -> nil
        end

      Map.put(proc, :reductions_per_sec, rate)
    end)
  end

  defp put_column(socket, server, changes) do
    column = Map.get(socket.assigns.columns, server, @default_column)
    columns = Map.put(socket.assigns.columns, server, Map.merge(column, Map.new(changes)))
    assign(socket, columns: columns)
  end

  # The parts erlang:memory() splits `total` into, as the Memory page shows them.
  defp memory(m) do
    %{
      total: m.total,
      parts: [
        {"Processes", m.processes},
        {"Binaries", m.binary},
        {"ETS", m.ets},
        {"Code", m.code},
        {"Atoms", m.atom},
        {"Other system", max(m.system - m.atom - m.binary - m.code - m.ets, 0)}
      ]
    }
  end

  defp panes(assigns) do
    panes =
      Enum.flat_map(assigns.checked, fn server ->
        case Enum.find(assigns.conn.connections, &(&1.server == server)) do
          nil -> []
          entry -> [pane(entry, Map.get(assigns.columns, server, @default_column), assigns)]
        end
      end)

    lowest = lowest_by_label(panes, assigns.metric)
    node_lowest = panes |> Enum.map(& &1.node_value) |> Enum.reject(&is_nil/1) |> min_or_nil()

    Enum.map(panes, fn pane ->
      pane
      |> mark_higher(lowest, assigns.metric)
      |> Map.put(:node_higher?, node_higher?(pane.node_value, node_lowest))
    end)
  end

  defp min_or_nil([]), do: nil
  defp min_or_nil(values), do: Enum.min(values)

  defp node_higher?(value, lowest), do: value != nil and lowest != nil and value > lowest

  defp node_metric?(metric), do: metric in @node_metrics

  defp node_value(nil, _metric), do: nil
  defp node_value(raw, metric) when metric in @node_metrics, do: Map.get(raw, metric)
  defp node_value(_raw, _metric), do: nil

  # The lowest value of each process label across the nodes that run it, or
  # nil when only one node runs it, so there is nothing to compare with.
  defp lowest_by_label(panes, metric) do
    panes
    |> Enum.flat_map(fn pane ->
      for proc <- pane.all,
          value = Map.get(proc, metric),
          value != nil,
          do: {Format.label(proc), pane.node_name, value}
    end)
    |> Enum.group_by(&elem(&1, 0))
    |> Map.new(fn {label, entries} ->
      nodes = entries |> Enum.uniq_by(&elem(&1, 1)) |> length()
      {label, if(nodes > 1, do: entries |> Enum.map(&elem(&1, 2)) |> Enum.min())}
    end)
  end

  defp mark_higher(pane, lowest, metric) do
    rows =
      Enum.map(pane.rows, fn proc ->
        Map.put(proc, :higher?, higher?(proc, Map.get(lowest, Format.label(proc)), metric))
      end)

    %{pane | rows: rows}
  end

  defp higher?(proc, lowest, metric) do
    value = Map.get(proc, metric)
    lowest != nil and value != nil and value > lowest
  end

  defp pane(entry, column, assigns) do
    procs = column.procs || []

    matched =
      Enum.filter(procs, &(matching?(assigns.filter, &1) and holds?(&1, assigns.metric)))

    {by, dir} = column.sort

    %{
      node_name: Atom.to_string(entry.node),
      node: entry.node,
      identity: entry.identity,
      status: entry.status,
      error: column.error,
      memory: column.memory,
      node_value: node_value(column.raw_memory, assigns.metric),
      procs_loaded: column.procs != nil,
      sort: column.sort,
      matched: length(matched),
      all: matched,
      rows: top(matched, sort_key(by, assigns.metric), dir, @row_limit)
    }
  end

  # The first `n` of `procs` in the order Enum.sort_by/3 gives, without
  # sorting the rest: a process is compared only with the last one kept.
  defp top(procs, key, dir, n) do
    ahead? = if dir == :desc, do: &>/2, else: &</2

    {_size, _worst, kept} =
      Enum.reduce(procs, {0, nil, []}, fn proc, {size, worst, kept} ->
        value = key.(proc)

        if size == n and not ahead?.(value, worst) do
          {size, worst, kept}
        else
          kept = Enum.take(insert_ahead(kept, {value, proc}, ahead?), n)
          {min(size + 1, n), elem(List.last(kept), 0), kept}
        end
      end)

    Enum.map(kept, &elem(&1, 1))
  end

  defp insert_ahead([], item, _ahead?), do: [item]

  defp insert_ahead([{value, _} = head | rest] = list, {new, _} = item, ahead?) do
    if ahead?.(new, value),
      do: [item | list],
      else: [head | insert_ahead(rest, item, ahead?)]
  end

  defp holds?(proc, metric) when metric in [:ets, :binary], do: metric_value(proc, metric) > 0
  defp holds?(_proc, _metric), do: true

  defp matching?("", _proc), do: true

  defp matching?(filter, proc) do
    needle = filter |> String.trim() |> String.downcase()

    [Format.pid(proc.pid), Format.label(proc), Format.mfa(proc.current_function)]
    |> Enum.any?(&String.contains?(String.downcase(&1), needle))
  end

  defp sort_key(:name, _metric), do: &String.downcase(Format.label(&1))
  defp sort_key(:metric, metric), do: &metric_value(&1, metric)

  defp metric_value(proc, metric), do: Map.get(proc, metric) || 0

  defp cell_class(%{higher?: true}), do: "num metric-higher"
  defp cell_class(_proc), do: "num"

  defp metric_cell(proc, :reductions_per_sec), do: rate_label(proc.reductions_per_sec)
  defp metric_cell(proc, :reductions), do: Format.number(proc.reductions)

  defp metric_cell(proc, metric) when metric in [:memory, :heap_size, :ets, :binary],
    do: Format.bytes(Map.get(proc, metric))

  defp metric_cell(proc, metric), do: Map.get(proc, metric)

  defp rate_label(nil), do: "—"
  defp rate_label(rate), do: "#{Format.number(round(rate))}/s"

  defp metric_label(metric), do: Keyword.fetch!(@metrics, metric)

  defp app_label(nil), do: "Unknown application"
  defp app_label({:direct, name}), do: name
  defp app_label({:kubectl, repository}), do: repository

  defp sort_aria({col, :asc}, col), do: "ascending"
  defp sort_aria({col, :desc}, col), do: "descending"
  defp sort_aria(_sort, _col), do: nil

  defp arrow({col, :asc}, col), do: "▲"
  defp arrow({col, :desc}, col), do: "▼"
  defp arrow(_sort, _col), do: ""

  @impl true
  def render(assigns) do
    connections = assigns.conn.connections
    connected = connected_count(connections)

    assigns =
      assign(assigns,
        connected: connected,
        choices:
          Enum.filter(connections, &(&1.status == :connected or &1.server in assigns.checked)),
        panes: if(length(connections) >= 2, do: panes(assigns), else: []),
        metrics: @metrics,
        metric_label: metric_label(assigns.metric),
        row_metric: assigns.metric,
        row_metric_label: metric_label(assigns.metric),
        node_metric: node_metric?(assigns.metric)
      )

    ~H"""
    <main class="wrap compare-page">
      <BeamdashWeb.Layouts.header
        active={:compare}
        syntax={@syntax}
        conn={@conn}
        ask={assigns[:ask]}
        ask_on={BeamdashWeb.JevSection.ask_on?(assigns[:jev_enabled])}
      />

      <p :if={@connected < 2} class="help" role="status">Connect a second node to compare.</p>

      <fieldset :if={@choices != []} class="compare-pick">
        <legend class="muted small">Nodes compared</legend>
        <label :for={entry <- @choices} class="compare-pick-item">
          <input
            type="checkbox"
            checked={entry.server in @checked}
            disabled={entry.server not in @checked and length(@checked) >= 3}
            phx-click="toggle"
            phx-value-node={Atom.to_string(entry.node)}
          />
          <span class="mono">{entry.node}</span>
          <span :if={entry.status != :connected} class="muted small">disconnected</span>
          <span
            :if={entry.server not in @checked and length(@checked) >= 3}
            class="muted small"
          >
            Compare shows up to three nodes
          </span>
        </label>
      </fieldset>

      <div :if={@checked != []} class="compare-tools">
        <form phx-change="metric" class="compare-metric">
          <label class="small">
            Compare by
            <select name="metric">
              <option
                :for={{key, label} <- @metrics}
                value={Atom.to_string(key)}
                selected={key == @metric}
              >
                {label}
              </option>
            </select>
          </label>
        </form>

        <form phx-change="filter" role="search" class="compare-filter">
          <input
            type="search"
            name="filter"
            value={@filter}
            placeholder="Filter processes in every column"
            aria-label="Filter processes in every column"
            phx-debounce="200"
          />
        </form>
      </div>

      <p :if={@checked != []} class="muted small compare-legend">
        <strong class="legend-red">Red</strong>
        marks a process whose {String.downcase(@metric_label)} is higher than its lowest value on another compared node. Processes are matched by name.
        <span :if={@node_metric}>
          The node total above each table is marked the same way against the other compared nodes.
        </span>
      </p>

      <div class="compare-grid">
        <section
          :for={pane <- @panes}
          class={["compare-col", pane.status != :connected && "compare-col-off"]}
          aria-label={"Node #{pane.node_name}"}
        >
          <header class="compare-col-head">
            <h2 class="mono">{pane.node_name}</h2>
            <p class="muted small">{app_label(pane.identity)}</p>
            <p :if={pane.status != :connected} class="compare-off" role="status">Disconnected</p>
          </header>

          <p
            :if={@node_metric and pane.node_value != nil}
            class={
              if pane.node_higher?, do: "compare-node-value metric-higher", else: "compare-node-value"
            }
          >
            <span class="muted small">{@metric_label}</span>
            <span class="mono">{Format.bytes(pane.node_value)}</span>
          </p>

          <p :if={pane.error} class="error" role="alert">{pane.error}</p>
          <p
            :if={!pane.procs_loaded and !pane.error and pane.status == :connected}
            class="muted small"
          >
            Reading the node…
          </p>

          <ul :if={pane.memory} class="compare-memory" aria-label="Memory">
            <li :for={{label, bytes} <- pane.memory.parts}>
              <span>{label}</span>
              <span class="mono">{Format.bytes(bytes)}</span>
            </li>
            <li>
              <span>Total</span>
              <span class="mono">{Format.bytes(pane.memory.total)}</span>
            </li>
          </ul>

          <div
            :if={pane.procs_loaded}
            class="process-table-scroll"
            tabindex="0"
            role="region"
            aria-label={"Processes on #{pane.node_name}"}
          >
            <table class="processes-table compare-table">
              <caption class="muted small">
                Showing {length(pane.rows)} of {pane.matched} matching processes
              </caption>
              <thead>
                <tr>
                  <th aria-sort={sort_aria(pane.sort, :name)}>
                    <button
                      type="button"
                      class="process-sort"
                      phx-click="sort"
                      phx-value-node={pane.node_name}
                      phx-value-col="name"
                    >
                      Name / initial call <span aria-hidden="true">{arrow(pane.sort, :name)}</span>
                    </button>
                  </th>
                  <th class="num" aria-sort={sort_aria(pane.sort, :metric)}>
                    <button
                      type="button"
                      class="process-sort"
                      phx-click="sort"
                      phx-value-node={pane.node_name}
                      phx-value-col="metric"
                    >
                      {@row_metric_label} <span aria-hidden="true">{arrow(pane.sort, :metric)}</span>
                    </button>
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr :if={pane.rows == []}>
                  <td colspan="2" class="process-empty">No processes match the filter.</td>
                </tr>
                <tr :for={p <- pane.rows}>
                  <td>
                    <div>{Format.label(p)}</div>
                    <div class="muted small mono">
                      {Format.pid(p.pid)} {Format.mfa(p.current_function)}
                    </div>
                  </td>
                  <td class={cell_class(p)}>{metric_cell(p, @row_metric)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </main>
    """
  end
end
