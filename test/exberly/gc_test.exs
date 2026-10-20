defmodule Exberly.GCTest do
  use ExUnit.Case, async: false
  alias Exberly.{GC, Target}
  alias Exberly.Test.Fixture

  setup do
    {peer, node} = Fixture.start_peer()
    on_exit(fn -> Fixture.stop_peer(peer) end)
    target = start_supervised!({Target, name: :"gc_target_#{System.unique_integer([:positive])}"})
    {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie(), target)
    :ok = Fixture.load(node)
    {:ok, pid} = :erpc.call(node, :exberly_fixture, :start, [])
    %{node: node, pid: pid}
  end

  test "snapshot includes process heaps, settings and monotonic node counters", %{
    node: node,
    pid: pid
  } do
    assert {:ok, first} = GC.snapshot(node)
    row = Enum.find(first.processes, &(&1.pid == pid))
    assert row.memory >= row.total_heap
    # the real entry point, not proc_lib:init_p/5, and the OTP behaviour
    assert row.initial_call == {:exberly_fixture, :init, 1}
    assert row.kind == :gen_server
    assert row.name == :exberly_fixture
    assert row.gc.minor_gcs >= 0
    assert row.gc.fullsweep_after >= 0
    assert row.gc.old_heap_size >= 0
    assert row.gc.min_heap_size > 0
    :erpc.call(node, :erlang, :garbage_collect, [pid])
    assert {:ok, second} = GC.snapshot(node)
    assert second.collections >= first.collections
    assert second.reclaimed_bytes >= first.reclaimed_bytes
  end

  test "rates use elapsed time, not the resettable process minor counter" do
    a = %{sampled_at_ms: 1000, collections: 10, reclaimed_bytes: 100}
    b = %{sampled_at_ms: 3000, collections: 16, reclaimed_bytes: 2100}
    assert GC.rates(nil, b) == nil
    assert GC.rates(a, b) == %{collections: 3.0, reclaimed: 1000}
    assert GC.rates(b, a) == nil
    assert GC.rates(a, a) == nil
  end

  test "trace records a full sweep and cleans flags on explicit stop", %{node: node, pid: pid} do
    assert {:ok, {:ok, collector}} = GC.trace(node, pid, self())
    monitor = Process.monitor(collector)
    assert :erpc.call(node, :erlang, :garbage_collect, [pid])
    assert_receive {:gc_trace_event, ^collector, event}, 2000
    assert event.kind == :major
    assert event.duration_us >= 0
    assert event.before >= 0 and event.after >= 0
    GC.stop(collector)
    assert_receive {:gc_trace_done, ^collector, :stopped}, 2000
    assert_receive {:DOWN, ^monitor, :process, ^collector, :normal}, 2000
    assert {:tracer, []} = :erpc.call(node, :erlang, :trace_info, [pid, :tracer])
  end

  test "existing tracing is preserved and duration is bounded", %{node: node, pid: pid} do
    assert {:ok, {:ok, collector}} = GC.trace(node, pid, self(), 1)
    monitor = Process.monitor(collector)
    assert {:ok, {:error, :already_traced}} = GC.trace(node, pid, self())
    assert {:tracer, ^collector} = :erpc.call(node, :erlang, :trace_info, [pid, :tracer])
    assert_receive {:gc_trace_done, ^collector, :stopped}, 2500
    assert_receive {:DOWN, ^monitor, :process, ^collector, :normal}, 1000
    assert {:tracer, []} = :erpc.call(node, :erlang, :trace_info, [pid, :tracer])
  end

  test "collector exits when its page owner dies", %{node: node, pid: pid} do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert {:ok, {:ok, collector}} = GC.trace(node, pid, owner)
    monitor = Process.monitor(collector)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^collector, :normal}, 2000
    assert {:tracer, []} = :erpc.call(node, :erlang, :trace_info, [pid, :tracer])
  end

  test "GC route renders disconnected state with navigation next to Memory" do
    conn = Plug.Test.conn(:get, "/gc") |> ExberlyWeb.Endpoint.call([])
    assert conn.status == 200
    assert conn.resp_body =~ "garbage collection"
    assert conn.resp_body =~ ~s(id="connect-form")
    assert conn.resp_body =~ ~s(href="/gc")
  end

  test "collection limit stops tracing and releases flags", %{node: node, pid: pid} do
    assert {:ok, {:ok, collector}} = GC.trace(node, pid, self(), 30)
    monitor = Process.monitor(collector)
    for _ <- 1..200, do: :erpc.call(node, :erlang, :garbage_collect, [pid])
    assert_receive {:gc_trace_done, ^collector, :limit}, 2000
    assert_receive {:DOWN, ^monitor, :process, ^collector, :normal}, 1000
    assert {:tracer, []} = :erpc.call(node, :erlang, :trace_info, [pid, :tracer])
  end

  test "selected process renders details, records GC, and clears on disconnect", %{
    node: node,
    pid: pid
  } do
    Fixture.put_jev_config(api_key: "test-key")
    view = ExberlyWeb.GCLive
    {:ok, socket} = view.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
    {:ok, snap} = GC.snapshot(node)

    socket =
      Phoenix.Component.assign(socket,
        node: node,
        status: :connected,
        snap: snap,
        syntax: :erlang,
        jev_enabled: true
      )

    {:noreply, socket} =
      view.handle_event("select", %{"pid" => Exberly.Format.pid(pid, :erlang)}, socket)

    # the panel loads (and then refreshes) on a detail tick, as on Processes
    assert_receive {:detail_tick, ^pid} = tick
    {:noreply, socket} = view.handle_info(tick, socket)
    assert socket.assigns.detail.pid == pid
    assert length(socket.assigns.history) == 1
    html = view.render(socket.assigns) |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "Old heap used"
    assert html =~ ~s(id="gc-force-collect")
    assert html =~ ~s(id="gc-details")
    assert html =~ "exberly_fixture"
    {:noreply, socket} = view.handle_event("trace", %{}, socket)
    collector = socket.assigns.collector
    assert is_pid(collector)
    html = view.render(socket.assigns) |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "Waiting for this process to collect"
    {trace_position, _} = :binary.match(html, "id=\"gc-trace-output\"")
    {advisor_position, _} = :binary.match(html, ~s(id="jev-gc"))
    assert trace_position < advisor_position
    {:noreply, socket} = view.handle_event("collect", %{}, socket)
    assert socket.assigns.gc_result.before > 0
    assert_receive event = {:gc_trace_event, ^collector, _}, 2000
    {:noreply, socket} = view.handle_info(event, socket)
    assert length(socket.assigns.events) >= 1
    html = view.render(socket.assigns) |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "full sweep"
    GC.stop(collector)
    assert_receive finished = {:gc_trace_done, ^collector, :stopped}, 2000
    {:noreply, socket} = view.handle_info(finished, socket)
    html = view.render(socket.assigns) |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "full sweep"
    {:noreply, socket} = view.handle_event("close_details", %{}, socket)
    assert socket.assigns.selected == nil
    assert socket.assigns.events == []

    {:noreply, socket} =
      view.handle_event("select", %{"pid" => Exberly.Format.pid(pid, :erlang)}, socket)

    assert_receive {:detail_tick, ^pid} = tick
    {:noreply, socket} = view.handle_info(tick, socket)
    {:noreply, socket} = view.handle_info({:exberly_target, {:disconnected, :user}}, socket)
    assert socket.assigns.selected == nil
    assert socket.assigns.detail == nil
    assert socket.assigns.collector == nil
  end

  test "idle trace finishing without collections explains the empty output", %{
    node: node,
    pid: pid
  } do
    view = ExberlyWeb.GCLive
    {:ok, socket} = view.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
    {:ok, detail} = Target.rpc(node, :exberly_agent, :process_details, [pid, -1])

    socket =
      Phoenix.Component.assign(socket,
        syntax: :erlang,
        status: :connected,
        node: node,
        selected: pid,
        detail: detail
      )

    assert socket.assigns.trace_seconds == 10

    for invalid <- ["0", "1000", "1oops", "2"] do
      {:noreply, unchanged} =
        view.handle_event("trace_duration", %{"duration" => invalid}, socket)

      assert unchanged.assigns.trace_seconds == 10
    end

    {:noreply, invalid} = view.handle_event("trace", %{"duration" => "1000"}, socket)
    assert invalid.assigns.collector == nil
    assert invalid.assigns.error =~ "valid GC trace duration"
    {:noreply, socket} = view.handle_event("trace_duration", %{"duration" => "1"}, socket)
    assert socket.assigns.trace_seconds == 1
    {:noreply, socket} = view.handle_event("trace", %{"duration" => "1"}, socket)
    collector = socket.assigns.collector
    assert is_pid(collector)
    assert socket.assigns.active_trace_seconds == 1
    {:noreply, socket} = view.handle_event("trace_duration", %{"duration" => "30"}, socket)
    assert socket.assigns.trace_seconds == 1
    html = view.render(socket.assigns) |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "Recording · up to 1 s"
    assert html =~ ~s(id="gc-trace-duration" name="duration" disabled)
    assert_receive done = {:gc_trace_done, ^collector, :stopped}, 2500
    {:noreply, socket} = view.handle_info(done, socket)
    html = view.render(socket.assigns) |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "GC trace"
    assert html =~ "No collections in this trace."
    assert socket.assigns.events == []
  end
end
