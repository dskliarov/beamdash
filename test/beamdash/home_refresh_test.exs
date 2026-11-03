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

  test "a tick schedules the next tick and starts one read" do
    me = self()
    ref = make_ref()

    socket =
      Phoenix.Component.assign(connected_socket(),
        selected: me,
        detail_ref: ref,
        detail_busy: false
      )

    {:noreply, socket} = HomeLive.handle_info({:detail_tick, me, ref}, socket)

    assert socket.assigns.detail_busy
    assert_receive {:detail_tick, ^me, ^ref}, 2000
  end

  test "a crashed detail read frees the next tick to read again" do
    socket = Phoenix.Component.assign(connected_socket(), selected: self(), detail_busy: true)

    {:noreply, socket} = HomeLive.handle_async(:detail, {:exit, :boom}, socket)

    refute socket.assigns.detail_busy
  end

  test "a tick from an earlier selection schedules nothing" do
    me = self()
    socket = Phoenix.Component.assign(connected_socket(), selected: me, detail_ref: make_ref())

    {:noreply, _socket} = HomeLive.handle_info({:detail_tick, me, make_ref()}, socket)

    refute_receive {:detail_tick, ^me, _}, 1100
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
