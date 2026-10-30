defmodule Beamdash.InsightsLiveReviewTest do
  use ExUnit.Case, async: true
  alias BeamdashWeb.InsightsLive

  defp socket do
    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = InsightsLive.mount(%{}, %{}, socket)
    Phoenix.Component.assign(socket, status: :connected, node: :old)
  end

  test "old analysis results cannot repopulate a view after disconnect" do
    detect = {:detect, make_ref()}
    groups = {:groups, make_ref()}

    socket =
      Phoenix.Component.assign(socket(),
        detecting: true,
        grouping: true,
        detect_request: detect,
        group_request: groups
      )

    {:noreply, socket} =
      InsightsLive.handle_info({:beamdash_target, {:disconnected, :nodedown}}, socket)

    refute socket.assigns.detecting
    refute socket.assigns.grouping
    {:noreply, socket} = InsightsLive.handle_async(detect, {:ok, [%{pid: self()}]}, socket)
    {:noreply, socket} = InsightsLive.handle_async(groups, {:ok, {:ok, [%{size: 1}]}}, socket)
    assert socket.assigns.findings == []
    assert socket.assigns.groups == nil

    current = {:detect, make_ref()}

    socket =
      Phoenix.Component.assign(socket,
        status: :connected,
        node: :new,
        detecting: true,
        detect_request: current
      )

    {:noreply, socket} = InsightsLive.handle_async(detect, {:ok, [%{pid: self()}]}, socket)
    assert socket.assigns.detect_request == current
    assert socket.assigns.findings == []
  end

  test "groups cap large snapshots at 1,500 processes" do
    procs =
      for n <- 1..1_501 do
        %{
          pid: :c.pid(0, n, 0),
          memory: n * 100,
          message_queue_len: rem(n, 5),
          status: :waiting,
          kind: :gen_server,
          initial_call: nil
        }
      end

    assert {:ok, groups} = Beamdash.Insights.Groups.group(procs, %{}, 2, num_runs: 1)
    assert Enum.sum(Enum.map(groups, & &1.size)) == 1_500
  end

  test "group counts identify the selected subset of the original snapshot" do
    request = {:groups, make_ref()}

    socket =
      Phoenix.Component.assign(socket(),
        grouping: true,
        group_request: request,
        group_total: 2_000
      )

    group = %{
      size: 900,
      share_pct: 60.0,
      memory: 100,
      queue: 0,
      rate: 0,
      running_pct: 0.0,
      kind: nil,
      initial_call: nil,
      members: []
    }

    {:noreply, socket} =
      InsightsLive.handle_async(request, {:ok, {:ok, [group, %{group | size: 600}]}}, socket)

    assert socket.assigns.group_total == 2_000
    assert socket.assigns.group_sampled == 1_500

    html =
      socket.assigns
      |> Map.put(:syntax, :erlang)
      |> InsightsLive.render()
      |> Phoenix.LiveViewTest.rendered_to_string()

    assert html =~ "1,500 of 2,000"
    assert html =~ "largest by memory"
  end

  test "clearing a trace invalidates an in-flight sequence graph" do
    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = BeamdashWeb.SeqLive.mount(%{}, %{}, socket)
    request = {:graph, make_ref()}

    socket =
      Phoenix.Component.assign(socket,
        graph_request: request,
        graphing: true,
        graph: %{messages: 3}
      )

    {:noreply, socket} = BeamdashWeb.SeqLive.handle_info({:beamdash_seq, :cleared}, socket)
    refute socket.assigns.graphing
    assert socket.assigns.graph == nil

    {:noreply, socket} =
      BeamdashWeb.SeqLive.handle_async(request, {:ok, {1, %{processes: 2}}}, socket)

    assert socket.assigns.graph == nil
  end
end
