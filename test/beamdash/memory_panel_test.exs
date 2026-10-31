defmodule Beamdash.MemoryPanelTest do
  use ExUnit.Case, async: true

  alias BeamdashWeb.MemoryLive

  test "inspection appears in a resizable side panel and can be closed" do
    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = MemoryLive.mount(%{}, %{}, socket)

    snap = %{
      memory: %{
        total: 100,
        processes: 40,
        processes_used: 40,
        system: 60,
        atom: 1,
        atom_used: 1,
        binary: 30,
        code: 10,
        ets: 10
      },
      alloc: nil,
      atom_count: 1,
      atom_limit: 10,
      process_count: 1,
      process_limit: 10,
      ets_count: 1,
      ets_limit: 10,
      module_count: 1,
      recon: false
    }

    inspect = %{
      pid: self(),
      name: nil,
      memory: 100,
      message_queue_len: 0,
      stack: [],
      status: :not_requested
    }

    socket =
      Phoenix.Component.assign(socket,
        syntax: :erlang,
        jev_enabled: false,
        status: :connected,
        snap: snap,
        tab: :binary,
        inspect: inspect
      )

    html = socket.assigns |> MemoryLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ ~s(class="proc-layout memory-layout with-panel")

    assert elem(:binary.match(html, ">Trend<"), 0) <
             elem(:binary.match(html, ~s(class="proc-layout memory-layout with-panel")), 0)

    assert html =~ ~s(id="memory-process-details")
    assert html =~ ~s(phx-hook="Resizer")
    assert html =~ ~s(phx-click="get_status")
    {:noreply, socket} = MemoryLive.handle_event("close_inspect", %{}, socket)
    html = socket.assigns |> MemoryLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    refute html =~ ~s(id="memory-process-details")
  end
end
