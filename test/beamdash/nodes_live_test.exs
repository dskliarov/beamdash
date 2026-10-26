defmodule Beamdash.NodesLiveTest do
  # The Nodes tab against two peers that are connected to each other. As in
  # the Logs tests, the page's callbacks are called directly on a socket.
  use ExUnit.Case, async: false

  alias Beamdash.Target
  alias Beamdash.Test.Fixture
  alias BeamdashWeb.NodesLive
  alias Phoenix.LiveView.{Lifecycle, Socket}

  setup do
    {peer, node} = Fixture.start_peer()
    {other_peer, other} = Fixture.start_peer()

    on_exit(fn ->
      Fixture.stop_peer(peer)
      Fixture.stop_peer(other_peer)
    end)

    target =
      start_supervised!({Target, name: :"nodes_target_#{System.unique_integer([:positive])}"})

    {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie(), target)
    true = :erpc.call(node, :net_kernel, :connect_node, [other])

    %{target: target, node: node, other: other}
  end

  defp mount(ctx) do
    socket = %Socket{
      transport_pid: self(),
      private: %{lifecycle: %Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = NodesLive.mount(%{}, %{"target" => ctx.target}, socket)
    socket
  end

  defp render(socket) do
    socket.assigns
    |> Map.put(:syntax, :erlang)
    |> NodesLive.render()
    |> Phoenix.LiveViewTest.rendered_to_string()
  end

  defp event(socket, name, params) do
    {:noreply, socket} = NodesLive.handle_event(name, params, socket)
    socket
  end

  # the start_async task's result, as LiveView hands it back
  defp async_result(socket, key) do
    assert_receive {:phoenix, :async_result, {:start, {_ref, nil, ^key, result}}}, 15_000
    {:noreply, socket} = NodesLive.handle_async(key, result, socket)
    socket
  end

  test "lists the attached node and its connections, hidden ones on request", ctx do
    html = ctx |> mount() |> render()
    assert html =~ ~r/<tr class="current">\s*<td class="mono"><strong>#{ctx.node}<\/strong>/
    assert html =~ ~s(phx-value-node="#{ctx.other}")
    refute html =~ ~s(phx-value-node="#{node()}")
    refute html =~ "hidden</td>"

    html = ctx |> mount() |> event("toggle_hidden", %{}) |> render()
    assert html =~ ~r/<input type="checkbox" checked/
    assert html =~ ~s(phx-value-node="#{ctx.other}")
    refute html =~ ~s(phx-value-node="#{node()}")
  end

  test "clicking another node connects to it", ctx do
    socket = ctx |> mount() |> event("switch", %{"node" => Atom.to_string(ctx.other)})
    assert socket.assigns.switching == ctx.other
    assert render(socket) =~ "Connecting…"

    socket = async_result(socket, :switch)
    assert socket.assigns.note == "Connected to #{ctx.other}."
    assert %{status: :connected, node: node} = Target.status(ctx.target)
    assert node == ctx.other
  end

  defp params(socket, params) do
    {:noreply, socket} = NodesLive.handle_params(params, "http://localhost/nodes", socket)
    socket
  end

  test "?switch= connects to the node, then goes back to ?return=", ctx do
    socket =
      ctx
      |> mount()
      |> params(%{"switch" => Atom.to_string(ctx.other), "return" => "/plugins/riak/ring"})

    assert socket.assigns.switching == ctx.other
    assert render(socket) =~ "Connecting to #{ctx.other}…"

    socket = async_result(socket, :switch)
    assert {:live, :redirect, %{to: "/plugins/riak/ring"}} = socket.redirected
    assert %{node: node} = Target.status(ctx.target)
    assert node == ctx.other
  end

  test "?switch= to the attached node goes straight back; without return it stays", ctx do
    socket =
      ctx |> mount() |> params(%{"switch" => Atom.to_string(ctx.node), "return" => "/apps"})

    assert {:live, :redirect, %{to: "/apps"}} = socket.redirected

    socket = ctx |> mount() |> params(%{"switch" => Atom.to_string(ctx.node)})
    assert socket.assigns.note == "Connected to #{ctx.node}."
  end

  test "?switch= refuses a node that isn't connected, and paths outside beamdash", ctx do
    socket =
      ctx |> mount() |> params(%{"switch" => "nobody@nowhere", "return" => "//evil.example"})

    assert socket.assigns.switching == nil
    assert socket.assigns.return_to == nil
    assert render(socket) =~ "nobody@nowhere is not connected to #{ctx.node}."
    assert %{node: node} = Target.status(ctx.target)
    assert node == ctx.node
  end

  test "a node not on the list is ignored", ctx do
    socket = ctx |> mount() |> event("switch", %{"node" => "nobody@nowhere"})
    assert socket.assigns.switching == nil
    assert %{node: node} = Target.status(ctx.target)
    assert node == ctx.node
  end
end
