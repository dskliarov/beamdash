defmodule Beamdash.InsightsHistoryTest do
  use ExUnit.Case, async: false

  alias Beamdash.Store
  alias BeamdashWeb.InsightsLive
  alias Phoenix.LiveView.{Lifecycle, Socket}

  @node "app@host"

  defp episode(at, pid, measure, kind, duration_ms, samples) do
    %{
      at: at,
      node: @node,
      pid: pid,
      measure: measure,
      data: %{
        kind: kind,
        text: "rising steadily",
        last_at: at + duration_ms,
        duration_ms: duration_ms,
        samples: samples,
        score: 3.0,
        now: 1
      }
    }
  end

  defp socket do
    socket = %Socket{private: %{lifecycle: %Lifecycle{}, live_temp: %{}}}
    {:ok, socket} = InsightsLive.mount(%{}, %{}, socket)
    Phoenix.Component.assign(socket, status: :connected, node: :app@host)
  end

  defp html(socket) do
    socket.assigns
    |> Map.put(:syntax, :erlang)
    |> InsightsLive.render()
    |> Phoenix.LiveViewTest.rendered_to_string()
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "beamdash_episodes_#{System.unique_integer([:positive])}")
    start_supervised!({Store, path: Path.join(dir, "events.sqlite3"), purge_interval: :infinity})
    on_exit(fn -> File.rm_rf(dir) end)
    :ok = Beamdash.Settings.put_snapshots_enabled(true)
    on_exit(fn -> :ok = Beamdash.Settings.put_snapshots_enabled(false) end)

    now = System.system_time(:millisecond)

    :ok =
      Store.record(:anomalies, [
        episode(now - 300_000, "#PID<0.1.0>", "memory", :rising, 60_000, 3),
        episode(now - 30_000, "#PID<0.2.0>", "queue", :spike, 30_000, 2)
      ])

    :ok
  end

  test "the history tab lists the stored episodes of the connected node" do
    {:noreply, socket} = InsightsLive.handle_event("tab", %{"tab" => "history"}, socket())
    html = html(socket)

    assert html =~ "#PID&lt;0.1.0&gt;"
    assert html =~ "#PID&lt;0.2.0&gt;"
    assert html =~ ~s(href="/?pid=%3C0.1.0%3E")
    assert html =~ "1 min 0 s"
    assert html =~ "30 s"
    assert html =~ "2 episodes in the last hour"

    {:noreply, socket} = InsightsLive.handle_event("tab", %{"tab" => "current"}, socket)
    refute html(socket) =~ "episodes in the last hour"
  end

  test "the history tab says so when the event store is not running" do
    stop_supervised!(Store)

    {:noreply, socket} = InsightsLive.handle_event("tab", %{"tab" => "history"}, socket())

    assert html(socket) =~ "History is off"
  end
end
