defmodule Beamdash.KubernetesLiveTest do
  # The Kubernetes page against two direct peers, for the session's connection and the
  # direct-connection message, and on canned kubectl output for the pod
  # itself. As in the Compare tests, the page's callbacks are called directly.
  use ExUnit.Case, async: false

  alias Beamdash.Target
  alias Beamdash.Test.Fixture
  alias BeamdashWeb.KubernetesLive
  alias Phoenix.LiveView.{Lifecycle, Socket}

  setup do
    {peer, node} = Fixture.start_peer()
    {other_peer, other} = Fixture.start_peer()

    on_exit(fn ->
      Fixture.stop_peer(peer)
      Fixture.stop_peer(other_peer)
    end)

    [first, second] =
      for name <- [:kube_a, :kube_b] do
        n = System.unique_integer([:positive])
        start_supervised!(Supervisor.child_spec({Target, name: :"#{name}_#{n}"}, id: {name, n}))
        :"#{name}_#{n}"
      end

    {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie(), first)
    {:ok, _} = Target.connect(Atom.to_string(other), Fixture.cookie(), second)

    %{first: first, second: second, node: node, other: other}
  end

  defp entry(server, node, status \\ :connected),
    do: %{server: server, node: node, status: status, reconnecting: nil, identity: nil}

  defp mount(entries, default) do
    socket =
      Fixture.with_conn(%Socket{
        transport_pid: self(),
        private: %{lifecycle: %Lifecycle{}, live_temp: %{}}
      })

    socket =
      Phoenix.Component.assign(
        socket,
        :conn,
        Map.merge(socket.assigns.conn, %{connections: entries, server: default})
      )

    {:ok, socket} = KubernetesLive.mount(%{}, %{}, socket)
    {:noreply, socket} = KubernetesLive.handle_info(:kube_tick, socket)
    socket
  end

  defp render(socket) do
    socket.assigns
    |> Map.put(:syntax, :erlang)
    |> KubernetesLive.render()
    |> Phoenix.LiveViewTest.rendered_to_string()
  end

  test "with no connection it asks for one", ctx do
    socket = mount([], ctx.first)
    assert render(socket) =~ "Connect a node to see its Kubernetes pod."
  end

  test "a directly made connection has no pod to show", ctx do
    socket = mount([entry(ctx.first, ctx.node)], ctx.first)

    html = render(socket)
    assert html =~ "made directly, not through kubectl"
    refute html =~ "kube-pod"
  end

  test "the page shows the session's connection", ctx do
    socket = mount([entry(ctx.first, ctx.node), entry(ctx.second, ctx.other)], ctx.second)
    assert socket.assigns.picked == ctx.second
  end

  test "the page falls back to a connected connection when the session's is down", ctx do
    socket =
      mount(
        [entry(ctx.first, ctx.node), entry(ctx.second, ctx.other, :disconnected)],
        ctx.second
      )

    assert socket.assigns.picked == ctx.first
  end

  test "a connection change message from the target does not crash the page", ctx do
    socket = mount([entry(ctx.first, ctx.node)], ctx.first)

    assert {:noreply, _} =
             KubernetesLive.handle_info({:beamdash_target, {:connected, ctx.node}}, socket)

    assert {:noreply, _} =
             KubernetesLive.handle_info({:beamdash_target, {:disconnected, :nodedown}}, socket)
  end

  test "a kubectl connection shows its pod, containers, images and events", ctx do
    source =
      {:kubectl, %{kubeconfig: nil, namespace: "prod", pod: "my-pod", container: "app"}}

    info = %{
      phase: "Running",
      node: "worker-3",
      ip: "10.0.0.5",
      host_ip: "192.168.1.7",
      host_network: false,
      owner: "ReplicaSet/my-app-7d9f",
      started: "2026-11-18T09:00:00Z",
      conditions: [%{type: "Ready", status: "True", reason: nil}],
      containers: [
        %{
          name: "app",
          image: "registry.example.com/my-app:1.4.2",
          image_id:
            "docker-pullable://registry.example.com/my-app@sha256:" <> String.duplicate("ab", 32),
          ready: true,
          restarts: 2,
          state: {:running, "2026-11-19T08:00:00Z"},
          requests: %{"cpu" => "100m"},
          limits: %{},
          ports: [%{name: "http", container_port: 8080, host_port: 30080, protocol: "TCP"}],
          liveness: %{
            action: "GET /healthz :8080",
            initial_delay: 15,
            period: 10,
            failure_threshold: 3,
            failures: 3
          },
          readiness: nil
        },
        %{
          name: "sidecar",
          image: "proxy:2",
          image_id: "",
          ready: false,
          restarts: 0,
          state: {:waiting, "ImagePullBackOff"},
          requests: %{},
          limits: %{},
          ports: [],
          liveness: nil,
          readiness: nil
        }
      ],
      events: [
        %{
          type: "Warning",
          reason: "BackOff",
          message: "Back-off restarting",
          count: 4,
          last_seen: "2026-11-19T08:30:00Z"
        }
      ]
    }

    socket =
      mount([entry(ctx.first, ctx.node)], ctx.first)
      |> Phoenix.Component.assign(
        sources: %{ctx.first => source},
        picked: ctx.first,
        read: %{server: ctx.first, result: {:ok, info}}
      )

    html = render(socket)

    assert html =~ "prod/my-pod"
    assert html =~ "container app"
    assert html =~ "registry.example.com/my-app:1.4.2"
    assert html =~ "sha256:abababababab"
    assert html =~ "ImagePullBackOff"
    assert html =~ "ReplicaSet/my-app-7d9f"
    assert html =~ "kube-warning"
    assert html =~ "Back-off restarting"
    assert html =~ "192.168.1.7"
    assert html =~ "30080"
    assert html =~ "GET /healthz :8080"
    assert html =~ "3 of 3"
  end

  test "a failed read shows kubectl's error", ctx do
    source = {:kubectl, %{kubeconfig: nil, namespace: "prod", pod: "gone", container: nil}}

    socket =
      mount([entry(ctx.first, ctx.node)], ctx.first)
      |> Phoenix.Component.assign(
        sources: %{ctx.first => source},
        picked: ctx.first,
        read: %{server: ctx.first, result: {:error, "pods \"gone\" not found"}}
      )

    assert render(socket) =~ "pods &quot;gone&quot; not found"
  end
end
