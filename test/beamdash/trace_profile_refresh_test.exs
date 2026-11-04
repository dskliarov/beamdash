defmodule Beamdash.TraceProfileRefreshTest do
  use ExUnit.Case, async: true

  alias BeamdashWeb.{ProfileLive, TraceLive}

  @modules [{:lists, [{:seq, 2}], []}]

  defp connected(view) do
    socket = %Phoenix.LiveView.Socket{private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}}}
    {:ok, socket} = view.mount(%{}, %{}, socket)
    Phoenix.Component.assign(socket, status: :connected, node: :fake@host)
  end

  test "trace asks for the module list in a task and applies it when it arrives" do
    {:noreply, socket} = TraceLive.handle_info(:load, connected(TraceLive))
    assert MapSet.member?(socket.assigns.in_flight, :modules)

    {:noreply, socket} =
      TraceLive.handle_async(:modules, {:ok, {:fake@host, {:ok, @modules}}}, socket)

    refute MapSet.member?(socket.assigns.in_flight, :modules)
    assert socket.assigns.modules == @modules
  end

  test "trace drops a module list read for a node that is no longer connected" do
    socket = Phoenix.Component.assign(connected(TraceLive), in_flight: MapSet.new([:modules]))

    {:noreply, socket} =
      TraceLive.handle_async(:modules, {:ok, {:other@host, {:ok, @modules}}}, socket)

    assert socket.assigns.modules == []
    refute MapSet.member?(socket.assigns.in_flight, :modules)
  end

  test "trace opens a ?mod= link once the module list has arrived" do
    {:noreply, socket} =
      TraceLive.handle_params(%{"mod" => "lists"}, "/trace?mod=lists", connected(TraceLive))

    assert socket.assigns.selected == nil

    {:noreply, socket} =
      TraceLive.handle_async(:modules, {:ok, {:fake@host, {:ok, @modules}}}, socket)

    assert socket.assigns.selected == :lists
  end

  test "profile checks tprof in a task, then reads the module list" do
    {:noreply, socket} = ProfileLive.handle_info(:load, connected(ProfileLive))
    assert MapSet.member?(socket.assigns.in_flight, :available)
    assert socket.assigns.available == nil

    {:noreply, socket} =
      ProfileLive.handle_async(:available, {:ok, {:fake@host, {:ok, true}}}, socket)

    assert socket.assigns.available == true
    assert MapSet.member?(socket.assigns.in_flight, :modules)

    {:noreply, socket} =
      ProfileLive.handle_async(:modules, {:ok, {:fake@host, {:ok, @modules}}}, socket)

    assert socket.assigns.modules == @modules
  end

  test "profile shows the reason when tprof is not in the release" do
    {:noreply, socket} = ProfileLive.handle_info(:load, connected(ProfileLive))

    {:noreply, socket} =
      ProfileLive.handle_async(:available, {:ok, {:fake@host, {:ok, {false, 26}}}}, socket)

    assert socket.assigns.available == {:no, 26}
    assert socket.assigns.modules == []
  end

  test "profile drops a tprof check finished for a node that is no longer connected" do
    socket = Phoenix.Component.assign(connected(ProfileLive), in_flight: MapSet.new([:available]))

    {:noreply, socket} =
      ProfileLive.handle_async(:available, {:ok, {:other@host, {:ok, true}}}, socket)

    assert socket.assigns.available == nil
    refute MapSet.member?(socket.assigns.in_flight, :available)
  end

  test "a ?mod=&fun=&arity= link keeps its function while the module list loads" do
    params = %{"mod" => "lists", "fun" => "seq", "arity" => "2"}
    uri = "/profile?mod=lists&fun=seq&arity=2"
    {:noreply, socket} = ProfileLive.handle_params(params, uri, connected(ProfileLive))
    assert socket.assigns.link == {params, uri}

    {:noreply, socket} =
      ProfileLive.handle_async(:modules, {:ok, {:fake@host, {:ok, @modules}}}, socket)

    assert {:lists, :seq, 2} in socket.assigns.picked
  end

  test "a ?mod= link waiting for the module list is dropped when the list fails" do
    {:noreply, socket} =
      ProfileLive.handle_params(%{"mod" => "lists"}, "/profile?mod=lists", connected(ProfileLive))

    assert socket.assigns.link != nil

    {:noreply, socket} =
      ProfileLive.handle_async(:modules, {:ok, {:fake@host, {:error, :boom}}}, socket)

    assert socket.assigns.link == nil
  end

  test "the newest ?mod= link replaces one still waiting for the module list" do
    {:noreply, socket} =
      ProfileLive.handle_params(%{"mod" => "lists"}, "/profile?mod=lists", connected(ProfileLive))

    {:noreply, socket} =
      ProfileLive.handle_params(%{"mod" => "other"}, "/profile?mod=other", socket)

    assert socket.assigns.link == {%{"mod" => "other"}, "/profile?mod=other"}
  end
end
