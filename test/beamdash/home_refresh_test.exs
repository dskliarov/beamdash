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

  test "a sys:trace click is pending at once, and a second click starts nothing" do
    me = self()

    socket =
      Phoenix.Component.assign(%{connected_socket() | transport_pid: self()},
        selected: me,
        sys_traced: MapSet.new(),
        sys_pending: nil
      )

    {:noreply, socket} = HomeLive.handle_event("sys_trace", %{}, socket)
    assert socket.assigns.sys_pending == {me, :enable}
    assert socket.assigns.dock_active == {:trace, me}

    assert {:noreply, ^socket} = HomeLive.handle_event("sys_trace", %{}, socket)
  end

  test "a sys:trace click on a traced process is a switch off, and opens no panel" do
    me = self()

    socket =
      Phoenix.Component.assign(%{connected_socket() | transport_pid: self()},
        selected: me,
        sys_traced: MapSet.new([me]),
        sys_pending: nil,
        dock_active: nil
      )

    {:noreply, socket} = HomeLive.handle_event("sys_trace", %{}, socket)
    assert socket.assigns.sys_pending == {me, :disable}
    assert socket.assigns.dock_active == nil
  end

  test "a failed sys:trace click shows its error and clears the pending flag" do
    me = self()

    socket =
      Phoenix.Component.assign(connected_socket(),
        selected: me,
        sys_pending: {me, :enable},
        sys_error: nil
      )

    {:noreply, socket} =
      HomeLive.handle_async({:sys_trace, me}, {:ok, {false, {:error, :timeout}}}, socket)

    assert socket.assigns.sys_pending == nil
    assert socket.assigns.sys_error
  end

  test "a sys:trace change refused as busy says to try again" do
    me = self()

    socket =
      Phoenix.Component.assign(connected_socket(),
        selected: me,
        sys_pending: {me, :disable},
        sys_error: nil
      )

    {:noreply, socket} =
      HomeLive.handle_async({:sys_trace, me}, {:ok, {true, {:error, :busy}}}, socket)

    assert socket.assigns.sys_error =~ "Try again"
  end

  test "a sys:trace result for a process no longer selected is not shown" do
    me = self()

    socket =
      Phoenix.Component.assign(connected_socket(),
        selected: make_ref(),
        sys_pending: {me, :enable},
        sys_error: nil
      )

    {:noreply, socket} =
      HomeLive.handle_async({:sys_trace, me}, {:ok, {false, {:error, :timeout}}}, socket)

    assert socket.assigns.sys_pending == nil
    assert socket.assigns.sys_error == nil
  end
end
