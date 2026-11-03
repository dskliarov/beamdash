defmodule Beamdash.HomeRefreshTest do
  use ExUnit.Case, async: true

  alias BeamdashWeb.HomeLive

  defp connected_socket do
    {:ok, socket} = HomeLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
    Phoenix.Component.assign(socket, status: :connected, node: :fake@host, syntax: :erlang)
  end

  test "a tick starts the list fetch, and a tick while it runs is skipped" do
    {:noreply, socket} = HomeLive.handle_info(:tick, connected_socket())
    assert socket.assigns.refreshing?

    {:noreply, again} = HomeLive.handle_info(:tick, socket)
    assert again.assigns.refreshing?
  end

  test "the fetched list and node info are applied when the task finishes" do
    {:noreply, socket} = HomeLive.handle_info(:tick, connected_socket())

    {:noreply, socket} =
      HomeLive.handle_async(:refresh, {:ok, {:ok, {[], %{}}}}, socket)

    refute socket.assigns.refreshing?
    assert socket.assigns.procs == []
    assert socket.assigns.error == nil
  end

  test "an error from the node is shown, and the next tick can fetch again" do
    {:noreply, socket} = HomeLive.handle_info(:tick, connected_socket())

    {:noreply, socket} =
      HomeLive.handle_async(:refresh, {:ok, {:error, :boom}}, socket)

    refute socket.assigns.refreshing?
    assert socket.assigns.error
  end

  test "a finished fetch is ignored once the node is no longer connected" do
    {:noreply, socket} = HomeLive.handle_info(:tick, connected_socket())
    socket = Phoenix.Component.assign(socket, status: :disconnected)

    {:noreply, socket} =
      HomeLive.handle_async(:refresh, {:ok, {:ok, {[:stale], %{}}}}, socket)

    refute socket.assigns.refreshing?
    assert socket.assigns.procs == []
  end
end
