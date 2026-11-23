defmodule Beamdash.KubectlPodInfoTest do
  use ExUnit.Case, async: true

  alias Beamdash.Kubectl

  @digest "sha256:" <> String.duplicate("ab", 32)

  defp pod_json do
    %{
      "metadata" => %{
        "name" => "my-pod",
        "ownerReferences" => [%{"kind" => "ReplicaSet", "name" => "my-app-7d9f"}]
      },
      "spec" => %{
        "nodeName" => "worker-3",
        "containers" => [
          %{
            "name" => "app",
            "image" => "registry.example.com/my-app:1.4.2",
            "resources" => %{
              "requests" => %{"cpu" => "100m", "memory" => "128Mi"},
              "limits" => %{"memory" => "256Mi"}
            },
            "ports" => [%{"name" => "http", "containerPort" => 8080, "hostPort" => 30080}],
            "livenessProbe" => %{
              "httpGet" => %{"path" => "/healthz", "port" => 8080},
              "initialDelaySeconds" => 15,
              "periodSeconds" => 10,
              "failureThreshold" => 3
            },
            "readinessProbe" => %{"tcpSocket" => %{"port" => 8080}}
          },
          %{
            "name" => "sidecar",
            "image" => "proxy:2",
            "ports" => [%{"containerPort" => 9090}]
          }
        ]
      },
      "status" => %{
        "phase" => "Running",
        "podIP" => "10.0.0.5",
        "hostIP" => "192.168.1.7",
        "startTime" => "2026-11-18T09:00:00Z",
        "conditions" => [
          %{"type" => "Ready", "status" => "True"},
          %{"type" => "PodScheduled", "status" => "True"}
        ],
        "containerStatuses" => [
          %{
            "name" => "app",
            "imageID" => "docker-pullable://registry.example.com/my-app@#{@digest}",
            "ready" => true,
            "restartCount" => 2,
            "state" => %{"running" => %{"startedAt" => "2026-11-19T08:00:00Z"}}
          },
          %{
            "name" => "sidecar",
            "imageID" => "",
            "ready" => false,
            "restartCount" => 0,
            "state" => %{"waiting" => %{"reason" => "ImagePullBackOff"}}
          }
        ]
      }
    }
  end

  defp events_json do
    %{
      "items" => [
        %{
          "type" => "Normal",
          "reason" => "Pulled",
          "message" => "Container image pulled",
          "count" => 1,
          "lastTimestamp" => "2026-11-19T07:59:00Z"
        },
        %{
          "type" => "Warning",
          "reason" => "BackOff",
          "message" => "Back-off restarting failed container",
          "count" => 4,
          "lastTimestamp" => "2026-11-19T08:30:00Z"
        },
        %{
          "type" => "Normal",
          "reason" => "Scheduled",
          "message" => "Assigned to worker-3",
          "eventTime" => "2026-11-18T09:00:00Z"
        }
      ]
    }
  end

  defp exec(pod_reply, events_reply) do
    fn args ->
      send(self(), {:exec, args})

      if "events" in args, do: events_reply.(), else: pod_reply.()
    end
  end

  test "reads the pod's node, owner, conditions, containers and their images" do
    exec = exec(fn -> {Jason.encode!(pod_json()), 0} end, fn -> {Jason.encode!(%{}), 0} end)

    assert {:ok, info} = Kubectl.pod_info(nil, "prod", "my-pod", exec)

    assert info.phase == "Running"
    assert info.node == "worker-3"
    assert info.ip == "10.0.0.5"
    assert info.owner == "ReplicaSet/my-app-7d9f"
    assert info.started == "2026-11-18T09:00:00Z"
    assert [%{type: "Ready", status: "True"}, %{type: "PodScheduled"}] = info.conditions

    assert [app, sidecar] = info.containers

    assert %{
             name: "app",
             image: "registry.example.com/my-app:1.4.2",
             image_id: "docker-pullable://registry.example.com/my-app@" <> _,
             ready: true,
             restarts: 2,
             state: {:running, "2026-11-19T08:00:00Z"},
             requests: %{"cpu" => "100m", "memory" => "128Mi"},
             limits: %{"memory" => "256Mi"}
           } = app

    assert %{
             name: "sidecar",
             ready: false,
             restarts: 0,
             state: {:waiting, "ImagePullBackOff"},
             requests: %{},
             limits: %{}
           } = sidecar
  end

  test "asks kubectl for the pod and for the events naming it, in the namespace" do
    exec = exec(fn -> {Jason.encode!(pod_json()), 0} end, fn -> {Jason.encode!(%{}), 0} end)

    assert {:ok, _} = Kubectl.pod_info(nil, "prod", "my-pod", exec)

    assert_received {:exec, ["get", "pod", "my-pod", "-n", "prod", "-o", "json"]}

    assert_received {:exec, args}
    assert ["get", "events", "-n", "prod", "--field-selector", selector, "-o", "json"] = args
    assert selector == "involvedObject.kind=Pod,involvedObject.name=my-pod"
  end

  test "lists the events newest first, with a count of 1 when none is given" do
    exec =
      exec(fn -> {Jason.encode!(pod_json()), 0} end, fn -> {Jason.encode!(events_json()), 0} end)

    assert {:ok, %{events: events}} = Kubectl.pod_info(nil, "prod", "my-pod", exec)

    assert [
             %{type: "Warning", reason: "BackOff", count: 4, last_seen: "2026-11-19T08:30:00Z"},
             %{reason: "Pulled", count: 1},
             %{reason: "Scheduled", count: 1, last_seen: "2026-11-18T09:00:00Z"}
           ] = events
  end

  test "reads host IP, host ports, probe settings and the probe failures recorded for them" do
    failure = fn message, count, container ->
      %{
        "type" => "Warning",
        "reason" => "Unhealthy",
        "message" => message,
        "count" => count,
        "lastTimestamp" => "2026-11-19T08:00:00Z",
        "involvedObject" => %{"fieldPath" => "spec.containers{#{container}}"}
      }
    end

    events = %{
      "items" => [
        failure.("Liveness probe failed: HTTP probe failed with statuscode: 500", 3, "app"),
        failure.("Readiness probe failed: dial tcp 10.0.0.5:8080", 2, "app"),
        failure.("Liveness probe failed: timeout", 9, "sidecar")
      ]
    }

    exec = exec(fn -> {Jason.encode!(pod_json()), 0} end, fn -> {Jason.encode!(events), 0} end)

    assert {:ok, info} = Kubectl.pod_info(nil, "prod", "my-pod", exec)

    assert info.host_ip == "192.168.1.7"
    assert info.host_network == false

    assert [app, sidecar] = info.containers
    assert app.ports == [%{name: "http", container_port: 8080, host_port: 30080, protocol: "TCP"}]

    assert %{action: "GET /healthz :8080", initial_delay: 15, period: 10, failure_threshold: 3} =
             app.liveness

    assert app.liveness.failures == 3

    assert %{action: "TCP :8080", initial_delay: 0, period: 10, failures: 2} = app.readiness

    assert sidecar.ports == [%{name: nil, container_port: 9090, host_port: nil, protocol: "TCP"}]
    assert sidecar.liveness == nil
    assert sidecar.readiness == nil
  end

  test "a pod with no events has an empty list" do
    exec = exec(fn -> {Jason.encode!(pod_json()), 0} end, fn -> {Jason.encode!(%{}), 0} end)

    assert {:ok, %{events: []}} = Kubectl.pod_info(nil, "prod", "my-pod", exec)
  end

  test "a failed pod read is reported with kubectl's output" do
    exec = exec(fn -> {"pods \"my-pod\" not found", 1} end, fn -> {"", 0} end)

    assert {:error, {:pod_failed, {1, "pods \"my-pod\" not found"}}} =
             Kubectl.pod_info(nil, "prod", "my-pod", exec)
  end

  test "a failed events read is reported separately" do
    exec = exec(fn -> {Jason.encode!(pod_json()), 0} end, fn -> {"forbidden", 1} end)

    assert {:error, {:events_failed, {1, "forbidden"}}} =
             Kubectl.pod_info(nil, "prod", "my-pod", exec)
  end

  test "output that is not JSON is an error, not a crash" do
    exec = exec(fn -> {"not json", 0} end, fn -> {"", 0} end)

    assert {:error, {:pod_failed, :invalid_json}} = Kubectl.pod_info(nil, "prod", "my-pod", exec)
  end
end
