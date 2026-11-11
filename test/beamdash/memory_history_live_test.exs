defmodule Beamdash.MemoryHistoryLiveTest do
  # Phoenix.LiveViewTest needs lazy_html, which this project lacks, so the
  # page's callbacks are called directly on a socket, as in the other LiveView tests.
  use ExUnit.Case, async: false

  alias Beamdash.{Settings, Store}
  alias BeamdashWeb.MemoryLive
  alias Phoenix.Component
  alias Phoenix.LiveView.{Lifecycle, Socket}

  @node "app@host"
  @minute 60_000

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "beamdash_memory_history_#{System.unique_integer([:positive])}"
      )

    start_supervised!({Store, path: Path.join(dir, "events.sqlite3"), purge_interval: :infinity})
    on_exit(fn -> File.rm_rf(dir) end)

    now = System.system_time(:millisecond)

    :ok =
      Store.record(:memory, [
        sample(now - 20 * @minute, 90, [table("rig_locks", 90)]),
        sample(now - 3_000, 100, [table("rig_locks", 100)]),
        sample(now - 2_000, 180, [table("rig_locks", 260)]),
        sample(now - 1_000, 170, [table("rig_locks", 250)])
      ])

    :ok = Settings.put_snapshots_enabled(true)
    on_exit(fn -> :ok = Settings.put_snapshots_enabled(false) end)

    :ok
  end

  defp sample(at, total, tables) do
    %{
      at: at,
      node: @node,
      data: %{
        "memory" => %{"total" => total, "processes" => 0},
        "atom_count" => 10,
        "ets_count" => length(tables),
        "tables" => tables
      }
    }
  end

  defp table(name, memory),
    do: %{"name" => name, "memory" => memory, "type" => "set", "size" => 1, "owner" => "<0.1.0>"}

  defp snap do
    %{
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
  end

  defp connected_socket do
    socket = %Socket{private: %{lifecycle: %Lifecycle{}, live_temp: %{}}}
    {:ok, socket} = MemoryLive.mount(%{}, %{}, socket)

    Component.assign(socket,
      syntax: :erlang,
      jev_enabled: false,
      status: :connected,
      node: @node,
      snap: snap()
    )
  end

  defp html(socket) do
    socket.assigns |> MemoryLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
  end

  defp open_history(socket) do
    {:noreply, socket} = MemoryLive.handle_event("page", %{"page" => "history"}, socket)
    socket
  end

  test "the History page lists the stored samples, newest first, with their changes" do
    socket = open_history(connected_socket())

    assert %{enabled: true, summary: summary, rows: [newest | _] = rows} = socket.assigns.stored
    assert summary.samples == 4
    assert summary.peak == 180
    assert %{memory: 170, memory_delta: -10, growing: []} = newest
    assert length(rows) == 4

    html = html(socket)
    assert html =~ ~s(class="mem-history")
    assert html =~ "rig_locks"
    assert html =~ ~s(id="stored-memory-trend")
    refute html =~ "Memory history is off"
  end

  test "the History chart plots one point per sample in the window" do
    socket = open_history(connected_socket())

    [_, points] =
      Regex.run(~r/id="stored-memory-trend".*?<polyline points="([^"]*)"/s, html(socket))

    assert length(String.split(points, " ")) == 4
  end

  test "a shorter window leaves out the older samples" do
    socket = open_history(connected_socket())
    assert socket.assigns.stored.summary.from == 90

    {:noreply, socket} =
      MemoryLive.handle_event("stored_window", %{"window" => "900"}, socket)

    assert socket.assigns.stored_window == 900
    assert socket.assigns.stored.summary.samples == 3
    assert socket.assigns.stored.summary.from == 100
  end

  test "with snapshot collection off, the History page says so and reads nothing" do
    :ok = Settings.put_snapshots_enabled(false)

    socket = open_history(connected_socket())

    assert socket.assigns.stored == %{enabled: false, rows: [], summary: nil}
    assert html(socket) =~ "Memory history is off"
  end
end
