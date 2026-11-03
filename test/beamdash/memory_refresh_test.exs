defmodule Beamdash.MemoryRefreshTest do
  use ExUnit.Case, async: true

  alias BeamdashWeb.MemoryLive

  defp connected_socket do
    {:ok, socket} = MemoryLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
    Phoenix.Component.assign(socket, status: :connected, node: :fake@host)
  end

  test "a tick starts one snapshot read, and a tick while it runs is skipped" do
    {:noreply, socket} = MemoryLive.handle_info(:tick, connected_socket())
    assert MapSet.member?(socket.assigns.in_flight, :snapshot)

    {:noreply, again} = MemoryLive.handle_info(:tick, socket)
    assert again.assigns.in_flight == socket.assigns.in_flight
  end

  test "on a top-list tab the tick makes one combined read, not a snapshot and a top list" do
    socket = Phoenix.Component.assign(connected_socket(), tab: :processes)
    {:noreply, socket} = MemoryLive.handle_info(:tick, socket)

    assert MapSet.member?(socket.assigns.in_flight, :page)
    refute MapSet.member?(socket.assigns.in_flight, :snapshot)
    refute Enum.any?(socket.assigns.in_flight, &match?({:top, _}, &1))
  end

  test "an error from the node is shown and clears the read" do
    socket = Phoenix.Component.assign(connected_socket(), in_flight: MapSet.new([:snapshot]))

    {:noreply, socket} =
      MemoryLive.handle_async({:memory, :snapshot}, {:ok, {:fake@host, {:error, :boom}}}, socket)

    refute MapSet.member?(socket.assigns.in_flight, :snapshot)
    assert socket.assigns.error
  end

  test "a read finished for a node that is no longer connected is dropped" do
    socket = Phoenix.Component.assign(connected_socket(), in_flight: MapSet.new([:snapshot]))

    {:noreply, socket} =
      MemoryLive.handle_async({:memory, :snapshot}, {:ok, {:other@host, {:error, :boom}}}, socket)

    refute MapSet.member?(socket.assigns.in_flight, :snapshot)
    assert socket.assigns.error == nil
  end

  test "top processes for an attribute the page no longer shows are dropped" do
    socket = connected_socket()

    {:noreply, socket} =
      MemoryLive.handle_async(
        {:memory, {:top, :reductions}},
        {:ok, {:fake@host, {:ok, {:processes, []}}}},
        socket
      )

    assert socket.assigns.top == nil
  end
end
