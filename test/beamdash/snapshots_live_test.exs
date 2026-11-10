defmodule Beamdash.SnapshotsLiveTest do
  # Phoenix.LiveViewTest needs lazy_html, which this project lacks, so the
  # page's callbacks are called directly on a socket, as in the other LiveView tests.
  use ExUnit.Case, async: false

  alias Beamdash.{Settings, Store}
  alias BeamdashWeb.SnapshotsLive
  alias Phoenix.LiveView.{Lifecycle, Socket}

  defp socket do
    socket = %Socket{private: %{lifecycle: %Lifecycle{}, live_temp: %{}}}
    {:ok, socket} = SnapshotsLive.mount(%{}, %{}, socket)
    socket
  end

  defp html(socket) do
    socket.assigns
    |> Map.put(:syntax, :erlang)
    |> SnapshotsLive.render()
    |> Phoenix.LiveViewTest.rendered_to_string()
  end

  defp utc(ms),
    do: ms |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%Y-%m-%d %H:%M:%S")

  defp snapshot(at, pid, reason, memory, rate \\ 0) do
    %{
      at: at,
      node: "app@host",
      pid: pid,
      reason: reason,
      data: %{
        "process" => %{
          "name" => "worker",
          "memory" => memory,
          "message_queue_len" => 0,
          "status" => "waiting"
        },
        "rate" => rate,
        "details" => nil
      }
    }
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "beamdash_snapshots_#{System.unique_integer([:positive])}")
    start_supervised!({Store, path: Path.join(dir, "events.sqlite3"), purge_interval: :infinity})
    on_exit(fn -> File.rm_rf(dir) end)

    now = System.system_time(:millisecond)
    older = now - 2_000
    newer = now - 1_000

    :ok =
      Store.record(
        :snapshots,
        [
          snapshot(older, "#PID<0.3.0>", "memory", 9_000_000),
          snapshot(newer, "#PID<0.1.0>", "memory", 5_000_000),
          snapshot(newer, "#PID<0.2.0>", "load", 1_000, 800_000)
        ]
      )

    :ok = Settings.put_snapshots_enabled(true)
    on_exit(fn -> :ok = Settings.put_snapshots_enabled(false) end)

    %{older: older, newer: newer}
  end

  test "with snapshot collection off, the page redirects to the processes tab" do
    :ok = Settings.put_snapshots_enabled(false)

    {:ok, socket} =
      SnapshotsLive.mount(%{}, %{}, %Socket{private: %{lifecycle: %Lifecycle{}, live_temp: %{}}})

    assert {:redirect, %{to: "/"}} = socket.redirected
  end

  test "lists one entry per snapshot time, newest first", ctx do
    html = html(socket())

    assert html =~ utc(ctx.newer)
    assert html =~ utc(ctx.older)
    assert :binary.match(html, utc(ctx.newer)) < :binary.match(html, utc(ctx.older))
  end

  test "selecting a snapshot shows its processes grouped by reason", ctx do
    {:noreply, socket} =
      SnapshotsLive.handle_event("select", %{"at" => to_string(ctx.newer)}, socket())

    html = html(socket)

    assert html =~ "Snapshot at #{utc(ctx.newer)} UTC · 2 processes"
    assert html =~ "Busiest · 1"
    assert html =~ "Most memory · 1"
    refute html =~ "Heap rising · "
    assert :binary.match(html, "Busiest · 1") < :binary.match(html, "Most memory · 1")
    assert html =~ "0.2.0"
    assert html =~ "0.1.0"
    refute html =~ "0.3.0"
    assert html =~ ~s(href="/?pid=%3C0.2.0%3E")
  end

  test "the latest snapshot is shown by default, and selecting another one replaces it", ctx do
    socket = socket()
    html = html(socket)

    assert html =~ "Snapshot at #{utc(ctx.newer)} UTC · 2 processes"
    refute html =~ "0.3.0"

    {:noreply, socket} =
      SnapshotsLive.handle_event("select", %{"at" => to_string(ctx.older)}, socket)

    html = html(socket)
    assert html =~ "Snapshot at #{utc(ctx.older)} UTC · 1 processes"
    assert html =~ "0.3.0"
    refute html =~ "0.1.0"
  end

  test "the details of a process are shown as labelled facts", ctx do
    details = %{
      "status" => "waiting",
      "priority" => "normal",
      "reductions" => 1_234,
      "links" => ["#PID<0.9.0>"],
      "monitors" => [],
      "monitored_by" => [],
      "memory" => %{"total" => 2_048, "heap" => 1_024, "binary_count" => 1, "binary_bytes" => 512},
      "gc" => %{"minor_gcs" => 3, "fullsweep_after" => 65_535},
      "mailbox" => %{"length" => 2, "messages" => [%{"id" => 1}, %{"id" => 2}]}
    }

    Store.record(
      :snapshots,
      [
        %{
          snapshot(ctx.older, "#PID<0.4.0>", "memory", 1_000)
          | data: %{"process" => %{"memory" => 1_000}, "rate" => 0, "details" => details}
        }
      ]
    )

    {:noreply, socket} =
      SnapshotsLive.handle_event("select", %{"at" => to_string(ctx.older)}, socket())

    assert html(socket) =~ ~s(phx-value-pid="#PID&lt;0.4.0&gt;")
    refute html(socket) =~ "Minor GCs"

    {:noreply, socket} =
      SnapshotsLive.handle_event("toggle_details", %{"pid" => "#PID<0.4.0>"}, socket)

    html = html(socket)
    assert html =~ "Hide"
    assert html =~ "<th>Minor GCs</th>"
    assert html =~ "<td>3</td>"
    assert html =~ "Mailbox · 2 messages"
    refute html =~ "&quot;minor_gcs&quot;"

    {:noreply, socket} =
      SnapshotsLive.handle_event("toggle_details", %{"pid" => "#PID<0.4.0>"}, socket)

    refute html(socket) =~ "Minor GCs"
  end

  test "a pid filter applies to the list and to the selected snapshot", ctx do
    {:noreply, socket} =
      SnapshotsLive.handle_event(
        "filter",
        %{"window" => "3600", "reason" => "all", "pid" => "#PID<0.2.0>"},
        socket()
      )

    html = html(socket)
    assert html =~ utc(ctx.newer)
    refute html =~ utc(ctx.older)

    {:noreply, socket} =
      SnapshotsLive.handle_event("select", %{"at" => to_string(ctx.newer)}, socket)

    html = html(socket)
    assert html =~ "0.2.0"
    refute html =~ "0.1.0"
  end

  test "the node memory is the newest sample, with changes against the oldest", ctx do
    refute html(socket()) =~ "Node memory"

    :ok =
      Store.record(:memory, [
        %{
          at: ctx.older,
          node: "app@host",
          data: %{
            "memory" => %{"total" => 1_000, "processes" => 600},
            "atom_count" => 10,
            "ets_count" => 3,
            "tables" => [%{"name" => "cache", "owner" => "owner", "size" => 5, "memory" => 2_048}]
          }
        },
        %{
          at: ctx.newer,
          node: "app@host",
          data: %{
            "memory" => %{"total" => 3_000, "processes" => 600},
            "atom_count" => 10,
            "ets_count" => 4,
            "tables" => [
              %{"name" => "cache", "owner" => "owner", "size" => 9, "memory" => 4_096},
              %{"name" => "fresh", "owner" => "owner", "size" => 1, "memory" => 100}
            ]
          }
        }
      ])

    html = html(socket())

    assert html =~ "Node memory · #{utc(ctx.newer)} UTC"
    assert html =~ ~s(<td class="num">no change</td>)
    assert html =~ ~s(<td class="num">new</td>)
    assert html =~ "fresh"
    assert html =~ "cache"
  end

  test "a process that spikes across snapshots is listed as a suspect and marked in them", ctx do
    spike = "#PID<0.99.0>"

    rows =
      for k <- 1..30, i <- 1..10 do
        at = ctx.newer + 1_000 - k * 1_000

        if i == 1 and (k == 1 or rem(k, 6) == 0),
          do: snapshot(at, spike, "memory", 100_000_000),
          else: snapshot(at, "#PID<0.#{i}.0>", "memory", 1_000 + i * 10)
      end

    :ok = Store.record(:snapshots, rows)

    html = html(socket())

    assert html =~ "Suspected processes"
    assert html =~ "#PID&lt;0.99.0&gt;"
    assert html =~ "badge-suspect"
  end

  test "says so when the event store is not running" do
    stop_supervised!(Store)

    assert html(socket()) =~ "Snapshots are off"
  end
end
