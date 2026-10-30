defmodule BeamdashWeb.InsightsLive do
  @moduledoc """
  Insights tab: what Nx finds in the node's processes, with no model
  asked and nothing sent anywhere.

    * **Anomalies** (`Beamdash.Insights.Anomaly`): processes whose memory,
      queue or reductions rate shifted, keeps rising or spiked over the
      last two minutes, or stands far above processes of its own kind.
      Re-checked on every refresh once enough samples are collected.
    * **Groups** (`Beamdash.Insights.Groups`): the processes clustered by
      behaviour with k-means, on request.
  """
  use Phoenix.LiveView

  alias Beamdash.{Format, ProcessStats, Target}
  alias Beamdash.Insights.{Anomaly, Groups}

  @refresh_ms 2_000
  @shown 25

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
        history: nil,
        findings: [],
        detecting: false,
        checked_at: nil,
        groups: nil,
        grouping: false,
        k: 5,
        error: nil
      )

    if connected?(socket) do
      :ok = Target.subscribe()
      send(self(), :tick)
    end

    {:ok, socket}
  end

  @impl true
  def handle_event("group", %{"k" => k}, socket) do
    k = if k in ~w(3 4 5 6 7 8), do: String.to_integer(k), else: 5
    %{procs: procs, rates: rates} = socket.assigns

    {:noreply,
     socket
     |> assign(k: k, grouping: true)
     |> start_async(:groups, fn -> Groups.group(procs, rates, k) end)}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @refresh_ms)
    {:noreply, if(socket.assigns.status == :connected, do: refresh(socket), else: socket)}
  end

  def handle_info({:beamdash_target, {:connected, node}}, socket) do
    {:noreply,
     socket
     |> assign(status: :connected, node: node)
     |> reset()
     |> refresh()}
  end

  def handle_info({:beamdash_target, {:disconnected, _}}, socket),
    do: {:noreply, socket |> assign(status: :disconnected) |> reset()}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:detect, {:ok, findings}, socket),
    do:
      {:noreply,
       assign(socket, findings: findings, detecting: false, checked_at: DateTime.utc_now())}

  def handle_async(:detect, {:exit, reason}, socket),
    do:
      {:noreply,
       assign(socket, detecting: false, error: "Anomaly check failed: #{inspect(reason)}")}

  def handle_async(:groups, {:ok, {:ok, groups}}, socket),
    do: {:noreply, assign(socket, groups: groups, grouping: false)}

  def handle_async(:groups, {:ok, {:error, message}}, socket),
    do: {:noreply, assign(socket, grouping: false, error: message)}

  def handle_async(:groups, {:exit, reason}, socket),
    do: {:noreply, assign(socket, grouping: false, error: "Grouping failed: #{inspect(reason)}")}

  defp reset(socket) do
    assign(socket,
      procs: [],
      by_pid: %{},
      rates: %{},
      prev_sample: %{},
      prev_at: nil,
      history: nil,
      findings: [],
      groups: nil,
      checked_at: nil
    )
  end

  defp refresh(socket) do
    case Target.processes() do
      {:ok, procs} ->
        now = System.monotonic_time(:microsecond)
        prev_at = socket.assigns.prev_at
        elapsed = if prev_at, do: now - prev_at, else: 0
        {rates, sample} = ProcessStats.table_rates(procs, socket.assigns.prev_sample, elapsed)

        history =
          if prev_at,
            do: Anomaly.track(socket.assigns.history, procs, rates, now),
            else: socket.assigns.history

        socket
        |> assign(
          procs: procs,
          by_pid: Map.new(procs, &{&1.pid, &1}),
          rates: rates,
          prev_sample: sample,
          prev_at: now,
          history: history,
          error: nil
        )
        |> detect()

      {:error, reason} ->
        assign(socket, error: Format.error(reason))
    end
  end

  # one check at a time, once enough samples are in
  defp detect(%{assigns: %{detecting: true}} = socket), do: socket

  defp detect(socket) do
    %{history: history, procs: procs, rates: rates} = socket.assigns

    case Anomaly.readiness(history) do
      {:ready, _} ->
        socket
        |> assign(detecting: true)
        |> start_async(:detect, fn -> Anomaly.detect(history, procs, rates) end)

      _ ->
        socket
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, readiness: Anomaly.readiness(assigns.history), shown: @shown)

    ~H"""
    <main class="wrap">
      <BeamdashWeb.Layouts.header
        active={:insights}
        syntax={@syntax}
        conn={assigns[:conn]}
        ask={assigns[:ask]}
        ask_on={BeamdashWeb.JevSection.show?(assigns[:jev_enabled])}
      />

      <p :if={@status != :connected} class="help">
        Not connected: enter a node above and click Connect.
      </p>
      <p :if={@error} class="error" role="alert">{@error}</p>

      <section :if={@status == :connected} class="insights-card" aria-labelledby="anomalies-heading">
        <div class="section-head">
          <h3 id="anomalies-heading">Anomalies</h3>
          <span class="muted small" role="status">
            {case @readiness do
              {:ready, s} ->
                "#{length(@findings)} found · last #{s} s of #{map_size(@history.procs)} busiest processes" <>
                  if(@checked_at,
                    do: " · checked #{Calendar.strftime(@checked_at, "%H:%M:%S")} UTC",
                    else: ""
                  )

              {:collecting, n, needed} ->
                "collecting samples · #{n} of #{needed}"
            end}
          </span>
        </div>
        <p class="muted small">
          Over the last two minutes, for the busiest processes (by memory, queue and reductions):
          a level that <strong>shifted</strong>
          and stayed, a <strong>steady rise</strong>,
          a <strong>spike</strong>
          in the latest sample, or a process far above <strong>peers</strong>
          of the same kind. Computed here with Nx; nothing is sent.
        </p>
        <p :if={match?({:ready, _}, @readiness) and @findings == []} class="muted">
          Nothing unusual.
        </p>
        <table :if={@findings != []} class="insights-table">
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
            <tr :for={f <- Enum.take(@findings, @shown)}>
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
          The processes clustered by how they behave (memory, queue, reductions rate, running or
          not, OTP kind) with k-means: a few groups instead of {length(@procs)} rows.
          Values are each group's medians.
        </p>
        <table :if={@groups} class="insights-table">
          <thead>
            <tr>
              <th class="num">Processes</th>
              <th class="num">Memory</th>
              <th class="num">Queue</th>
              <th class="num">Reductions/s</th>
              <th class="num">Running</th>
              <th>Mostly</th>
              <th>Biggest</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={g <- @groups}>
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
        href: "/?" <> URI.encode_query(%{"pid" => Format.pid(assigns.pid)})
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
end
