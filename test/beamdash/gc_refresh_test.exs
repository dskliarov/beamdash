defmodule Beamdash.GCRefreshTest do
  use ExUnit.Case, async: true

  alias BeamdashWeb.GCLive

  defp connected_socket do
    {:ok, socket} = GCLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
    Phoenix.Component.assign(socket, status: :connected, node: :fake@host)
  end

  test "a tick starts one snapshot read, and a tick while it runs is skipped" do
    {:noreply, socket} = GCLive.handle_info(:tick, connected_socket())
    assert MapSet.member?(socket.assigns.in_flight, :snapshot)

    {:noreply, again} = GCLive.handle_info(:tick, socket)
    assert again.assigns.in_flight == socket.assigns.in_flight
  end

  test "a snapshot error is shown and clears the read" do
    socket = Phoenix.Component.assign(connected_socket(), in_flight: MapSet.new([:snapshot]))

    {:noreply, socket} =
      GCLive.handle_async(:snapshot, {:ok, {:fake@host, {:error, :boom}}}, socket)

    refute MapSet.member?(socket.assigns.in_flight, :snapshot)
    assert socket.assigns.error
  end

  test "a snapshot finished for a node that is no longer connected is dropped" do
    socket = Phoenix.Component.assign(connected_socket(), in_flight: MapSet.new([:snapshot]))

    {:noreply, socket} =
      GCLive.handle_async(:snapshot, {:ok, {:other@host, {:error, :boom}}}, socket)

    refute MapSet.member?(socket.assigns.in_flight, :snapshot)
    assert socket.assigns.error == nil
  end

  test "a detail read for a process that is no longer selected is dropped" do
    socket = Phoenix.Component.assign(connected_socket(), selected: self())

    {:noreply, socket} =
      GCLive.handle_async(:detail, {:ok, {spawn(fn -> :ok end), {:ok, :undefined}}}, socket)

    assert socket.assigns.detail == nil
    assert socket.assigns.detail_note == nil
  end

  test "a detail read for the selected process that has exited says so" do
    pid = self()
    socket = Phoenix.Component.assign(connected_socket(), selected: pid)

    {:noreply, socket} = GCLive.handle_async(:detail, {:ok, {pid, {:ok, :undefined}}}, socket)

    assert socket.assigns.detail_note == "The process has exited."
  end
end
