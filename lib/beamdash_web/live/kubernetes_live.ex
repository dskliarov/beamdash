defmodule BeamdashWeb.KubernetesLive do
  @moduledoc """
  The Kubernetes pod behind a connected node: its phase, node, owner and
  conditions, each container with the image it runs and that image's digest,
  readiness, restarts, state and resources, and the events `kubectl describe`
  lists for the pod. The page shows the session's selected connection, chosen in
  the connection bar. A connection made directly has no pod to show.
  """
  use Phoenix.LiveView

  alias Beamdash.{Format, Kubectl, Target}

  @refresh_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    socket = assign(socket, picked: nil, sources: %{}, read: nil, in_flight: MapSet.new())

    if connected?(socket), do: send(self(), :kube_tick)
    {:ok, socket}
  end

  @impl true
  def handle_info(:kube_tick, socket) do
    Process.send_after(self(), :kube_tick, @refresh_ms)
    {:noreply, refresh(socket)}
  end

  def handle_info({:beamdash_target, _}, socket), do: {:noreply, refresh(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_async({:kube, server}, result, socket) do
    socket = assign(socket, in_flight: MapSet.delete(socket.assigns.in_flight, server))

    if server == socket.assigns.picked,
      do: {:noreply, assign(socket, read: %{server: server, result: unwrap(result)})},
      else: {:noreply, socket}
  end

  defp refresh(socket) do
    connected = Enum.filter(socket.assigns.conn.connections, &(&1.status == :connected))
    sources = Map.new(connected, &{&1.server, Target.source(&1.server)})
    picked = pick(socket.assigns.conn.server, connected)

    socket
    |> assign(sources: sources, picked: picked)
    |> read(picked, Map.get(sources, picked))
  end

  defp pick(default, connected) do
    servers = Enum.map(connected, & &1.server)

    cond do
      default in servers -> default
      servers != [] -> hd(servers)
      true -> nil
    end
  end

  # Each read runs in a task, and a read still running is not started again.
  defp read(socket, server, {:kubectl, source}) do
    if MapSet.member?(socket.assigns.in_flight, server) do
      socket
    else
      socket
      |> assign(in_flight: MapSet.put(socket.assigns.in_flight, server))
      |> start_async({:kube, server}, fn ->
        Kubectl.pod_info(source.kubeconfig, source.namespace, source.pod)
      end)
    end
  end

  defp read(socket, _server, _source), do: socket

  defp unwrap({:ok, {:ok, info}}), do: {:ok, info}
  defp unwrap({:ok, {:error, reason}}), do: {:error, Format.error(reason)}
  defp unwrap({:exit, reason}), do: {:error, Format.error({:exit, reason})}

  @impl true
  def render(assigns) do
    connected = Enum.filter(assigns.conn.connections, &(&1.status == :connected))
    source = Map.get(assigns.sources, assigns.picked)
    read = if assigns.read && assigns.read.server == assigns.picked, do: assigns.read.result
    info = if(match?({:ok, _}, read), do: elem(read, 1))

    assigns =
      assign(assigns,
        connected: connected,
        direct?: source == :direct,
        pod: if(match?({:kubectl, _}, source), do: elem(source, 1)),
        kube_error: if(match?({:error, _}, read), do: elem(read, 1)),
        info: info,
        ports: port_rows(info),
        probes: probe_rows(info)
      )

    ~H"""
    <main class="wrap kube-page">
      <BeamdashWeb.Layouts.header
        active={:kubernetes}
        syntax={@syntax}
        conn={@conn}
        ask={assigns[:ask]}
        ask_on={BeamdashWeb.JevSection.ask_on?(assigns[:jev_enabled])}
      />

      <p :if={@connected == []} class="help" role="status">
        Connect a node to see its Kubernetes pod.
      </p>

      <p :if={@direct?} class="help" role="status">
        This connection was made directly, not through kubectl, so it has no pod to show.
      </p>

      <section :if={@pod} class="kube-pod">
        <h2 class="kube-title">
          <span class="mono">{@pod.namespace}/{@pod.pod}</span>
          <span :if={@pod.container} class="muted small">container {@pod.container}</span>
        </h2>

        <p :if={@info == nil and @kube_error == nil} class="muted small" role="status">
          Reading the pod…
        </p>
        <p :if={@kube_error} class="error" role="alert">{@kube_error}</p>

        <div :if={@info} class="sys-grid">
          <section class="sys-card" aria-label="Pod">
            <h3>Pod</h3>
            <table class="sys-table">
              <tr>
                <th>Phase</th>
                <td>{@info.phase || "—"}</td>
              </tr>
              <tr>
                <th>Node</th>
                <td class="mono">{@info.node || "—"}</td>
              </tr>
              <tr>
                <th>Pod IP</th>
                <td class="mono">{@info.ip || "—"}</td>
              </tr>
              <tr>
                <th>Host IP</th>
                <td class="mono">{@info.host_ip || "—"}</td>
              </tr>
              <tr>
                <th>Host network</th>
                <td>{if @info.host_network, do: "yes", else: "no"}</td>
              </tr>
              <tr>
                <th>Restarts</th>
                <td>{Enum.sum(for c <- @info.containers, do: c.restarts)}</td>
              </tr>
              <tr>
                <th>Owner</th>
                <td class="mono">{@info.owner || "—"}</td>
              </tr>
              <tr>
                <th>Started</th>
                <td>{@info.started || "—"}</td>
              </tr>
            </table>
          </section>

          <section class="sys-card" aria-label="Conditions">
            <h3>Conditions</h3>
            <table class="sys-table">
              <tr :for={c <- @info.conditions}>
                <th>{c.type}</th>
                <td>
                  <span class={["dot", c.status != "True" && "dot-wait"]} aria-hidden="true"></span>
                  {c.status}{if c.reason, do: " · #{c.reason}"}
                </td>
              </tr>
            </table>
          </section>

          <section class="sys-card sys-wide" aria-label="Containers">
            <h3>Containers</h3>
            <table class="sys-table sys-cols">
              <thead>
                <tr>
                  <th>Container</th>
                  <th>Image</th>
                  <th>Digest</th>
                  <th>Ready</th>
                  <th>Restarts</th>
                  <th>State</th>
                  <th>Requests / limits</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={c <- @info.containers}>
                  <td class="mono">{c.name}</td>
                  <td class="mono">{c.image}</td>
                  <td class="mono" title={c.image_id}>{digest(c.image_id)}</td>
                  <td>{if c.ready, do: "yes", else: "no"}</td>
                  <td>{c.restarts}</td>
                  <td>{state_label(c.state)}</td>
                  <td class="small">{resources(c.requests)} / {resources(c.limits)}</td>
                </tr>
              </tbody>
            </table>
          </section>

          <section class="sys-card sys-wide" aria-label="Host ports">
            <h3>Host ports</h3>
            <p :if={@ports == []} class="muted small">No ports are declared.</p>
            <table :if={@ports != []} class="sys-table sys-cols">
              <thead>
                <tr>
                  <th>Container</th>
                  <th>Name</th>
                  <th>Container port</th>
                  <th>Host port</th>
                  <th>Protocol</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={{container, p} <- @ports}>
                  <td class="mono">{container}</td>
                  <td class="mono">{p.name || "—"}</td>
                  <td>{p.container_port}</td>
                  <td>{p.host_port || "—"}</td>
                  <td>{p.protocol}</td>
                </tr>
              </tbody>
            </table>
          </section>

          <section class="sys-card sys-wide" aria-label="Probes">
            <h3>Probes</h3>
            <p :if={@probes == []} class="muted small">No liveness or readiness probes.</p>
            <table :if={@probes != []} class="sys-table sys-cols">
              <thead>
                <tr>
                  <th>Container</th>
                  <th>Probe</th>
                  <th>Action</th>
                  <th>Initial delay</th>
                  <th>Period</th>
                  <th>Failures</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={{container, kind, p} <- @probes}>
                  <td class="mono">{container}</td>
                  <td>{kind}</td>
                  <td class="mono">{p.action}</td>
                  <td>{p.initial_delay}s</td>
                  <td>every {p.period}s</td>
                  <td>{p.failures} of {p.failure_threshold}</td>
                </tr>
              </tbody>
            </table>
            <p :if={@probes != []} class="muted small">
              Failures are the probe-failure events Kubernetes recorded for this pod. Kubernetes does
              not record successful probe runs, so no success count is shown.
            </p>
          </section>

          <section class="sys-card sys-wide" aria-label="Events">
            <h3>Events</h3>
            <p :if={@info.events == []} class="muted small">No events for this pod.</p>
            <table :if={@info.events != []} class="sys-table sys-cols">
              <thead>
                <tr>
                  <th>Type</th>
                  <th>Reason</th>
                  <th>Message</th>
                  <th>Count</th>
                  <th>Last seen</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={e <- @info.events} class={e.type == "Warning" && "kube-warning"}>
                  <td>{e.type}</td>
                  <td class="mono">{e.reason}</td>
                  <td>{e.message}</td>
                  <td>{e.count}</td>
                  <td class="small">{e.last_seen || "—"}</td>
                </tr>
              </tbody>
            </table>
          </section>
        </div>
      </section>
    </main>
    """
  end

  defp port_rows(nil), do: []
  defp port_rows(info), do: for(c <- info.containers, p <- c.ports, do: {c.name, p})

  defp probe_rows(nil), do: []

  defp probe_rows(info) do
    for c <- info.containers,
        {kind, p} <- [{"Liveness", c.liveness}, {"Readiness", c.readiness}],
        p,
        do: {c.name, kind, p}
  end

  defp state_label({:running, at}), do: "running since #{at}"
  defp state_label({:waiting, reason}), do: "waiting · #{reason}"
  defp state_label({:terminated, reason, code}), do: "terminated · #{reason} (exit #{code})"
  defp state_label(_), do: "unknown"

  defp digest(nil), do: "—"

  defp digest(image_id) do
    case String.split(image_id, "@", parts: 2) do
      [_, digest] -> String.slice(digest, 0, 19)
      _ -> image_id
    end
  end

  defp resources(map) when map_size(map) == 0, do: "—"
  defp resources(map), do: Enum.map_join(map, ", ", fn {k, v} -> "#{k} #{v}" end)
end
