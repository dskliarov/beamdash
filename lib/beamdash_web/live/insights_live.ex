defmodule BeamdashWeb.InsightsLive do
  @moduledoc """
  Insights tab: what Nx finds in the node's processes, with no model
  asked and nothing sent anywhere.

    * **Anomalies** (`Beamdash.AnomalyMonitor`): processes whose memory,
      queue or reductions rate shifted, keeps rising or spiked over the
      last two minutes, or stands far above processes of its own kind.
      The current check is read from the monitor; the history is what the
      sampler stored from it.
    * **Groups** (`Beamdash.Insights.Groups`): the processes clustered by
      behaviour with k-means, on request.
  """
  use Phoenix.LiveView

  alias Beamdash.{AnomalyMonitor, Format, ProcessStats, Settings, Store, Target}
  alias Beamdash.Insights.{Anomaly, Groups}

  @refresh_ms 2_000
  @shown 25
  @episode_window_ms 3_600_000
  @episode_limit 5_000
  @episode_refresh_ms 10_000

  @impl true
  def mount(_params, _session, socket) do
    %{status: status, node: node} = Target.status()

    socket =
      assign(socket,
        status: status,
        node: node,
        procs: [],
        by_pid: %{},
        rates: %{},
        prev_sample: %{},
        prev_at: nil,
        anomaly: AnomalyMonitor.current(),
        groups: nil,
        grouping: false,
        group_request: nil,
        group_total: nil,
        group_sampled: nil,
        k: 5,
        error: nil,
        tab: :current,
        episodes: [],
        episodes_at: nil,
        episodes_enabled: Process.whereis(Store) != nil
      )

    if connected?(socket) do
      :ok = Target.subscribe()
      :ok = AnomalyMonitor.watch()
      send(self(), :tick)
    end

    {:ok, socket}
  end

  @impl true
  def handle_event(
        "group",
        %{"k" => k},
        %{assigns: %{status: :connected, grouping: false}} = socket
      ) do
    k = if k in ~w(3 4 5 6 7 8), do: String.to_integer(k), else: 5
    %{procs: procs, rates: rates} = socket.assigns
    request = {:groups, make_ref()}

    {:noreply,
     socket
     |> assign(
       k: k,
       grouping: true,
       group_request: request,
       group_total: length(procs),
       group_sampled: nil,
       groups: nil
     )
     |> start_async(request, fn -> Groups.group(procs, rates, k) end)}
  end

  def handle_event("group", _, socket), do: {:noreply, socket}

  def handle_event("tab", %{"tab" => "history"}, socket),
    do: {:noreply, socket |> assign(tab: :history) |> load_episodes()}

  def handle_event("tab", _, socket), do: {:noreply, assign(socket, tab: :current)}

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @refresh_ms)
    socket = if(socket.assigns.status == :connected, do: refresh(socket), else: socket)
    {:noreply, refresh_episodes(socket)}
  end

  def handle_info({:beamdash_target, {:connected, node}}, socket) do
    {:noreply,
     socket
     |> assign(status: :connected, node: node)
     |> reset()
     |> refresh()}
  end

  def handle_info({:beamdash_target, {:disconnected, _}}, socket),
    do: {:noreply, socket |> assign(status: :disconnected, node: nil) |> reset()}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_async(
        {:groups, _} = request,
        {:ok, {:ok, groups}},
        %{assigns: %{group_request: request}} = socket
      ),
      do:
        {:noreply,
         assign(socket,
           groups: groups,
           grouping: false,
           group_request: nil,
           group_sampled: Enum.sum(Enum.map(groups, & &1.size))
         )}

  def handle_async(
        {:groups, _} = request,
        {:ok, {:error, message}},
        %{assigns: %{group_request: request}} = socket
      ),
      do: {:noreply, assign(socket, grouping: false, group_request: nil, error: message)}

  def handle_async(
        {:groups, _} = request,
        {:exit, reason},
        %{assigns: %{group_request: request}} = socket
      ),
      do:
        {:noreply,
         assign(socket,
           grouping: false,
           group_request: nil,
           error: "Grouping failed: #{inspect(reason)}"
         )}

  def handle_async({:groups, _}, _, socket), do: {:noreply, socket}

  defp reset(socket) do
    socket =
      if socket.assigns.group_request,
        do: cancel_async(socket, socket.assigns.group_request),
        else: socket

    assign(socket,
      procs: [],
      by_pid: %{},
      rates: %{},
      prev_sample: %{},
      prev_at: nil,
      groups: nil,
      grouping: false,
      group_request: nil,
      group_total: nil,
      group_sampled: nil
    )
  end

  defp refresh(socket) do
    case Target.processes() do
      {:ok, procs} ->
        now = System.monotonic_time(:microsecond)
        prev_at = socket.assigns.prev_at
        elapsed = if prev_at, do: now - prev_at, else: 0
        {rates, sample} = ProcessStats.table_rates(procs, socket.assigns.prev_sample, elapsed)

        assign(socket,
          procs: procs,
          by_pid: Map.new(procs, &{&1.pid, &1}),
          rates: rates,
          prev_sample: sample,
          prev_at: now,
          anomaly: AnomalyMonitor.current(),
          error: nil
        )

      {:error, reason} ->
        assign(socket, error: Format.error(reason))
    end
  end

  @impl true
  def render(assigns) do
    history = Settings.snapshots_enabled?()
    tab = if history, do: assigns.tab, else: :current
    episode_procs = Map.new(assigns.by_pid, fn {pid, proc} -> {inspect(pid), proc} end)

    assigns =
      assign(assigns, shown: @shown, history: history, tab: tab, episode_procs: episode_procs)

    ~H"""
    <main class="wrap">
      <BeamdashWeb.Layouts.header
        active={:insights}
        syntax={@syntax}
        conn={assigns[:conn]}
        ask={assigns[:ask]}
        ask_on={BeamdashWeb.JevSection.ask_on?(assigns[:jev_enabled])}
      />

      <p :if={@status != :connected} class="help">
        Not connected: enter a node above and click Connect.
      </p>
      <p :if={@error} class="error" role="alert">{@error}</p>

      <section :if={@status == :connected} class="insights-card" aria-labelledby="anomalies-heading">
        <div class="section-head">
          <h3 id="anomalies-heading">Anomalies</h3>
          <span :if={@tab == :current} class="muted small" role="status">
            {case @anomaly.readiness do
              {:ready, s} ->
                "#{length(@anomaly.findings)} found · last #{s} s of #{@anomaly.tracked} busiest processes" <>
                  if(@anomaly.checked_at,
                    do: " · checked #{Calendar.strftime(@anomaly.checked_at, "%H:%M:%S")} UTC",
                    else: ""
                  )

              {:collecting, n, needed} ->
                "collecting samples · #{n} of #{needed}"
            end}
          </span>
          <span :if={@tab == :history} class="muted small" role="status">
            {Format.number(length(@episodes))} episodes in the last hour · newest {min(
              length(@episodes),
              @shown
            )} shown
          </span>
        </div>
        <div :if={@history} class="tab-bar" role="tablist" aria-label="Anomalies view">
          <button
            type="button"
            role="tab"
            class="small-btn"
            aria-selected={to_string(@tab == :current)}
            phx-click="tab"
            phx-value-tab="current"
          >
            Current
          </button>
          <button
            type="button"
            role="tab"
            class="small-btn"
            aria-selected={to_string(@tab == :history)}
            phx-click="tab"
            phx-value-tab="history"
          >
            History
          </button>
        </div>

        <div :if={@tab == :current}>
          <p class="muted small">
            Over the last two minutes, for the busiest processes (by memory, queue and reductions):
            a level that <strong>shifted</strong>
            and stayed, a <strong>steady rise</strong>,
            a <strong>spike</strong>
            in the latest sample, or a process far above <strong>peers</strong>
            of the same kind. Computed here with Nx; nothing is sent.
          </p>
          <p :if={match?({:ready, _}, @anomaly.readiness) and @anomaly.findings == []} class="muted">
            Nothing unusual.
          </p>
          <table :if={@anomaly.findings != []} class="insights-table anomaly-table">
            <colgroup>
              <col style="width: 28%" />
              <col style="width: 12%" />
              <col style="width: 38%" />
              <col style="width: 12%" />
              <col style="width: 10%" />
            </colgroup>
            <thead>
              <tr>
                <th>Process</th>
                <th>Measure</th>
                <th>Finding</th>
                <th class="num">Now</th>
                <th class="num" title="How strong the finding is (a t or z statistic)">Score</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={f <- Enum.take(@anomaly.findings, @shown)}>
                <td><.process pid={f.pid} by_pid={@by_pid} syntax={@syntax} /></td>
                <td>{measure_label(f.measure)}</td>
                <td>
                  <span class={["badge", "badge-#{f.kind}"]}>{kind_label(f.kind)}</span>
                  {f.text}
                </td>
                <td class="num mono">{Anomaly.show(f.measure, f.now)}</td>
                <td class="num">{f.score}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <div :if={@tab == :history}>
          <p class="muted small">
            Each row is one process and measure flagged in consecutive checks, taken every two
            seconds. Episodes are saved every 30 seconds, so one still open is not listed yet. The
            duration runs from the first check to the last. A check that does not flag it ends the
            episode.
          </p>
          <p :if={!@episodes_enabled} class="error" role="alert">
            History is off: the event store is not running.
          </p>
          <p :if={@episodes_enabled and @episodes == []} class="muted">
            No anomalies in the last hour.
          </p>
          <table :if={@episodes != []} class="insights-table anomaly-table">
            <colgroup>
              <col style="width: 20%" />
              <col style="width: 10%" />
              <col style="width: 24%" />
              <col style="width: 16%" />
              <col style="width: 16%" />
              <col style="width: 8%" />
              <col style="width: 6%" />
            </colgroup>
            <thead>
              <tr>
                <th>Process</th>
                <th>Measure</th>
                <th>Finding</th>
                <th>Started (UTC)</th>
                <th>Last seen (UTC)</th>
                <th class="num">Duration</th>
                <th class="num">Samples</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={e <- Enum.take(@episodes, @shown)}>
                <td class="mono small">
                  <.process pid={e.pid} by_pid={@episode_procs} syntax={@syntax} />
                </td>
                <td>{measure_label(e.measure)}</td>
                <td>
                  <span class={["badge", "badge-#{e.kind}"]}>{kind_label(e.kind)}</span>
                  {e.text}
                </td>
                <td class="mono small">{utc(e.started_at)}</td>
                <td class="mono small">{utc(e.last_at)}</td>
                <td class="num">{duration(e.duration_ms)}</td>
                <td class="num">{e.samples}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section :if={@status == :connected} class="insights-card" aria-labelledby="groups-heading">
        <div class="section-head">
          <h3 id="groups-heading">Groups</h3>
          <form phx-submit="group" class="inline-form">
            <label for="groups-k" class="small muted">Groups</label>
            <select id="groups-k" name="k">
              <option :for={k <- 3..8} value={k} selected={k == @k}>{k}</option>
            </select>
            <button type="submit" class="small-btn" disabled={@grouping or @procs == []}>
              {if @grouping, do: "Grouping…", else: "Group processes"}
            </button>
          </form>
        </div>
        <p class="muted small">
          Each row is a group of processes that behave alike. The processes are clustered on
          memory, mailbox length, work rate, whether they are running, and their OTP behaviour
          (k-means). The numbers are medians of the group, so one large process does not skew
          them. "Typical" means close to the median process on this node.
        </p>
        <p :if={@groups} class="muted small">
          Grouped {Format.number(@group_sampled)} of {Format.number(@group_total)} processes from the snapshot.
          <span :if={@group_sampled < @group_total}>
            The selection contains the largest by memory; percentages describe that subset.
          </span>
        </p>
        <details :if={@groups} class="insights-legend small">
          <summary>What the columns mean</summary>
          <dl>
            <dt>Group</dt>
            <dd>
              What the group's processes have in common, and a hint on what to check.
            </dd>
            <dt>Processes</dt>
            <dd>How many processes are in the group, and their share of the grouped snapshot.</dd>
            <dt>Memory</dt>
            <dd>Memory of a typical process in the group.</dd>
            <dt>Queue</dt>
            <dd>
              Messages waiting in a typical process's mailbox. Above zero means work is waiting
              to be handled.
            </dd>
            <dt>Reductions/s</dt>
            <dd>
              Work rate of a typical process. Reductions roughly count function calls, so a high
              rate means the process is busy computing.
            </dd>
            <dt>Running</dt>
            <dd>
              Share of processes that were running or ready to run at the sample. A low value
              means they are waiting for messages.
            </dd>
            <dt>Mostly</dt>
            <dd>
              The most common OTP behaviour (gen_server, supervisor, ...) and start function in
              the group, with its share.
            </dd>
            <dt>Biggest</dt>
            <dd>The five largest processes by memory. Click one to open it on the Processes tab.</dd>
          </dl>
        </details>
        <table :if={@groups} class="insights-table">
          <thead>
            <tr>
              <th>Group</th>
              <th class="num" title="How many processes are in the group">Processes</th>
              <th class="num" title="Memory of a typical process in the group">Memory</th>
              <th class="num" title="Messages waiting in a typical process's mailbox">Queue</th>
              <th class="num" title="Work rate of a typical process">Reductions/s</th>
              <th class="num" title="Share of processes running or ready to run">Running</th>
              <th title="Most common OTP behaviour and start function">Mostly</th>
              <th title="Five largest processes by memory">Biggest</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={g <- @groups}>
              <td class="small">
                <strong>{g.summary}</strong>
                <div class="muted">{g.note}</div>
              </td>
              <td class="num">{g.size} <span class="muted small">({g.share_pct}%)</span></td>
              <td class="num mono">{Format.bytes(g.memory)}</td>
              <td class="num">{Format.number(g.queue)}</td>
              <td class="num">{Format.number(g.rate)}</td>
              <td class="num">{round(g.running_pct)}%</td>
              <td class="small">
                <div :if={g.kind}>
                  {elem(g.kind, 0)} <span class="muted">{elem(g.kind, 1)}%</span>
                </div>
                <div :if={g.initial_call} class="mono">
                  {Format.mfa(elem(g.initial_call, 0), @syntax)}
                  <span class="muted">{elem(g.initial_call, 1)}%</span>
                </div>
              </td>
              <td class="small">
                <div :for={p <- g.members}>
                  <.process pid={p.pid} by_pid={@by_pid} syntax={@syntax} />
                  <span class="muted">{Format.bytes(p.memory)}</span>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </section>
    </main>
    """
  end

  attr :pid, :any, required: true
  attr :by_pid, :map, required: true
  attr :syntax, :atom, required: true

  # a link that opens the process on the Processes tab
  defp process(assigns) do
    assigns =
      assign(assigns,
        text:
          case assigns.by_pid[assigns.pid] do
            %{registered_name: _, initial_call: _} = p ->
              Format.label(p, assigns.syntax) || Format.pid(assigns.pid, assigns.syntax)

            _ ->
              Format.pid(assigns.pid, assigns.syntax)
          end,
        href:
          "/?" <>
            URI.encode_query(%{
              "pid" => String.replace_prefix(Format.pid(assigns.pid), "#PID", "")
            })
      )

    ~H"""
    <.link navigate={@href} class="mono" title={Format.pid(@pid, @syntax)}>{@text}</.link>
    """
  end

  defp measure_label(:memory), do: "Memory"
  defp measure_label(:queue), do: "Queue"
  defp measure_label(:rate), do: "Reductions/s"

  defp kind_label(:shift), do: "shift"
  defp kind_label(:rising), do: "rising"
  defp kind_label(:spike), do: "spike"
  defp kind_label(:peer_outlier), do: "peers"

  defp refresh_episodes(%{assigns: %{tab: :history, episodes_at: at}} = socket) do
    if at == nil or System.system_time(:millisecond) - at >= @episode_refresh_ms,
      do: load_episodes(socket),
      else: socket
  end

  defp refresh_episodes(socket), do: socket

  defp load_episodes(
         %{assigns: %{episodes_enabled: true, status: :connected, node: node}} = socket
       ) do
    now = System.system_time(:millisecond)

    rows =
      Store.query(:anomalies,
        from: now - @episode_window_ms,
        node: to_string(node),
        limit: @episode_limit
      )

    assign(socket, episodes: Enum.map(rows, &episode/1), episodes_at: now)
  end

  defp load_episodes(socket), do: assign(socket, episodes: [], episodes_at: nil)

  defp episode(row) do
    %{
      pid: row.pid,
      measure: String.to_existing_atom(row.measure),
      kind: String.to_existing_atom(row.data["kind"]),
      text: row.data["text"],
      started_at: row.at,
      last_at: row.data["last_at"],
      duration_ms: row.data["duration_ms"],
      samples: row.data["samples"]
    }
  end

  defp utc(ms),
    do: ms |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%Y-%m-%d %H:%M:%S")

  defp duration(ms) do
    s = div(ms, 1_000)

    cond do
      s < 60 -> "#{s} s"
      s < 3_600 -> "#{div(s, 60)} min #{rem(s, 60)} s"
      true -> "#{div(s, 3_600)} h #{div(rem(s, 3_600), 60)} min"
    end
  end
end
