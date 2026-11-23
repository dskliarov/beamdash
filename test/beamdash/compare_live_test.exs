defmodule Beamdash.CompareLiveTest do
  # The Compare page against two peers, each on its own target. A third
  # target is never connected, so its column shows the error. As in the
  # Nodes tests, the page's callbacks are called directly on a socket.
  use ExUnit.Case, async: false

  alias Beamdash.{Format, Target}
  alias Beamdash.Test.Fixture
  alias BeamdashWeb.CompareLive
  alias Phoenix.LiveView.{Lifecycle, Socket}

  setup do
    {peer, node} = Fixture.start_peer()
    {other_peer, other} = Fixture.start_peer()

    on_exit(fn ->
      Fixture.stop_peer(peer)
      Fixture.stop_peer(other_peer)
    end)

    [first, second, idle] =
      for name <- [:compare_a, :compare_b, :compare_idle] do
        n = System.unique_integer([:positive])
        start_supervised!(Supervisor.child_spec({Target, name: :"#{name}_#{n}"}, id: {name, n}))
        :"#{name}_#{n}"
      end

    {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie(), first)
    {:ok, _} = Target.connect(Atom.to_string(other), Fixture.cookie(), second)

    %{first: first, second: second, idle: idle, node: node, other: other}
  end

  defp entry(server, node, status \\ :connected),
    do: %{server: server, node: node, status: status, reconnecting: nil, identity: nil}

  defp mount(entries) do
    socket =
      Fixture.with_conn(%Socket{
        transport_pid: self(),
        private: %{lifecycle: %Lifecycle{}, live_temp: %{}}
      })

    socket = set_connections(socket, entries)
    {:ok, socket} = CompareLive.mount(%{}, %{}, socket)
    socket
  end

  defp set_connections(socket, entries),
    do:
      Phoenix.Component.assign(socket, :conn, Map.put(socket.assigns.conn, :connections, entries))

  defp tick(socket) do
    {:noreply, socket} = CompareLive.handle_info(:compare_tick, socket)
    socket
  end

  # the start_async task's result, as LiveView hands it back
  defp finish_read(socket, server) do
    assert_receive {:phoenix, :async_result, {:start, {_ref, nil, {:compare, ^server}, result}}},
                   15_000

    {:noreply, socket} = CompareLive.handle_async({:compare, server}, result, socket)
    socket
  end

  defp render(socket) do
    socket.assigns
    |> Map.put(:syntax, :erlang)
    |> CompareLive.render()
    |> Phoenix.LiveViewTest.rendered_to_string()
  end

  defp event(socket, name, params) do
    {:noreply, socket} = CompareLive.handle_event(name, params, socket)
    socket
  end

  test "connection events from the target are ignored, not a crash", ctx do
    socket = mount([entry(ctx.first, ctx.node), entry(ctx.second, ctx.other)])

    assert {:noreply, _} =
             CompareLive.handle_info({:beamdash_target, {:connected, ctx.node}}, socket)

    assert {:noreply, _} =
             CompareLive.handle_info({:beamdash_target, {:disconnected, :nodedown}}, socket)
  end

  test "the first three connected nodes start checked, a fourth cannot be checked", ctx do
    fourth = make_ref()

    socket =
      mount([
        entry(ctx.first, ctx.node),
        entry(ctx.second, ctx.other),
        entry(ctx.idle, :third@host),
        entry(fourth, :fourth@host)
      ])

    assert length(socket.assigns.checked) == 3
    assert ctx.idle in socket.assigns.checked
    refute fourth in socket.assigns.checked

    html = render(socket)
    assert html =~ "Compare shows up to three nodes"
    assert html =~ ~r/<input[^>]*disabled[^>]*phx-value-node="fourth@host"/
  end

  test "fewer than two connections redirects to System", ctx do
    socket = mount([entry(ctx.first, ctx.node)])

    assert {:live, :redirect, %{to: "/system"}} = socket.redirected
  end

  test "a failing node shows its error while the others load", ctx do
    socket =
      mount([
        entry(ctx.first, ctx.node),
        entry(ctx.second, ctx.other),
        entry(ctx.idle, :ghost@nowhere)
      ])
      |> tick()

    socket = socket |> finish_read(ctx.first) |> finish_read(ctx.second) |> finish_read(ctx.idle)

    html = render(socket)
    assert html =~ "Not connected."
    assert html =~ ~s(aria-label="Node #{ctx.node}")
    assert html =~ ~s(aria-label="Node #{ctx.other}")
    assert html =~ "code_server"
  end

  test "a checked node that disconnects keeps its column, greyed out", ctx do
    socket =
      mount([entry(ctx.first, ctx.node), entry(ctx.second, ctx.other)])
      |> tick()
      |> finish_read(ctx.first)
      |> finish_read(ctx.second)

    socket =
      set_connections(socket, [
        entry(ctx.first, ctx.node),
        entry(ctx.second, ctx.other, :disconnected)
      ])
      |> tick()

    html = render(socket)
    assert html =~ ~s(class="compare-col compare-col-off")
    assert html =~ "Disconnected"
    assert ctx.second in socket.assigns.checked
  end

  test "the name filter applies to every column", ctx do
    socket =
      mount([entry(ctx.first, ctx.node), entry(ctx.second, ctx.other)])
      |> tick()
      |> finish_read(ctx.first)
      |> finish_read(ctx.second)
      |> event("filter", %{"filter" => "code_server"})

    html = render(socket)
    assert length(Regex.scan(~r/code_server/, html)) >= 2

    html = event(socket, "filter", %{"filter" => "no-such-process-zz"}) |> render()
    assert length(Regex.scan(~r/No processes match the filter\./, html)) == 2
  end

  test "each column sorts on its own", ctx do
    socket =
      mount([entry(ctx.first, ctx.node), entry(ctx.second, ctx.other)])
      |> tick()
      |> finish_read(ctx.first)
      |> finish_read(ctx.second)
      |> event("sort", %{"node" => Atom.to_string(ctx.node), "col" => "metric"})

    assert socket.assigns.columns[ctx.first].sort == {:metric, :desc}
    assert socket.assigns.columns[ctx.second].sort == {:name, :asc}
  end

  test "the metric selector changes the value shown; rates need a second read", ctx do
    socket =
      mount([entry(ctx.first, ctx.node), entry(ctx.second, ctx.other)])
      |> tick()
      |> finish_read(ctx.first)
      |> finish_read(ctx.second)
      |> event("metric", %{"metric" => "reductions_per_sec"})

    assert socket.assigns.metric == :reductions_per_sec
    assert render(socket) =~ "Reductions/s"
    refute Enum.any?(socket.assigns.columns[ctx.first].procs, &is_number(&1.reductions_per_sec))

    socket = socket |> tick() |> finish_read(ctx.first) |> finish_read(ctx.second)
    assert Enum.any?(socket.assigns.columns[ctx.first].procs, &is_number(&1.reductions_per_sec))
    assert render(socket) =~ ~r/\d\/s/
  end

  test "the process table shows the selected metric's value for each node", ctx do
    socket =
      mount([entry(ctx.first, ctx.node), entry(ctx.second, ctx.other)])
      |> tick()
      |> finish_read(ctx.first)
      |> finish_read(ctx.second)

    for {metric, label, cell} <- [
          {"message_queue_len", "Msg queue", &to_string(&1.message_queue_len)},
          {"reductions", "Reductions", &Format.number(&1.reductions)},
          {"memory", "Memory", &Format.bytes(&1.memory)},
          {"heap_size", "Heap size", &Format.bytes(&1.heap_size)}
        ] do
      html = socket |> event("metric", %{"metric" => metric}) |> render()
      assert html =~ Regex.compile!(">\\s*#{Regex.escape(label)}\\s*<span")

      for server <- [ctx.first, ctx.second] do
        proc =
          Enum.min_by(socket.assigns.columns[server].procs, &String.downcase(Format.label(&1)))

        assert html =~ ~r/<td class="num(?: metric-higher)?">#{Regex.escape(cell.(proc))}<\/td>/
      end
    end
  end

  test "a process's value above its lowest value on the other nodes is marked", ctx do
    socket =
      mount([entry(ctx.first, ctx.node), entry(ctx.second, ctx.other)])
      |> tick()
      |> finish_read(ctx.first)
      |> finish_read(ctx.second)

    base = hd(socket.assigns.columns[ctx.first].procs)
    high = %{base | reductions: 1_000_000_000}
    low = %{base | reductions: 1}

    columns =
      socket.assigns.columns
      |> Map.put(ctx.first, Map.merge(socket.assigns.columns[ctx.first], %{procs: [high]}))
      |> Map.put(ctx.second, Map.merge(socket.assigns.columns[ctx.second], %{procs: [low]}))

    html =
      socket
      |> Phoenix.Component.assign(:columns, columns)
      |> event("metric", %{"metric" => "reductions"})
      |> render()

    assert html =~ ~s(<td class="num metric-higher">#{Format.number(1_000_000_000)}</td>)
    refute html =~ ~s(<td class="num metric-higher">1</td>)
    assert html =~ ~s(<td class="num">1</td>)
    assert html =~ "compare-legend"
    assert html =~ "is higher than its lowest value on another compared node"
  end

  test "ets and binary list only the processes that hold them", ctx do
    socket =
      mount([entry(ctx.first, ctx.node), entry(ctx.second, ctx.other)])
      |> tick()
      |> finish_read(ctx.first)
      |> finish_read(ctx.second)

    base = hd(socket.assigns.columns[ctx.first].procs)
    owner = %{base | ets: 1_000, binary: 0}
    idle = %{base | pid: self(), ets: 0, binary: 0}

    columns =
      Map.put(
        socket.assigns.columns,
        ctx.first,
        Map.merge(socket.assigns.columns[ctx.first], %{procs: [owner, idle]})
      )

    socket = Phoenix.Component.assign(socket, :columns, columns)

    html = socket |> event("metric", %{"metric" => "ets"}) |> render()
    assert html =~ ~r/aria-label="Processes on #{ctx.node}".*?Showing 1 of 1 matching processes/s
    refute html =~ Format.pid(self())

    html = socket |> event("metric", %{"metric" => "binary"}) |> render()
    assert html =~ ~r/aria-label="Processes on #{ctx.node}".*?Showing 0 of 0 matching processes/s
  end

  test "a node-level metric shows each node's value above its process table", ctx do
    socket =
      mount([entry(ctx.first, ctx.node), entry(ctx.second, ctx.other)])
      |> tick()
      |> finish_read(ctx.first)
      |> finish_read(ctx.second)
      |> event("metric", %{"metric" => "ets"})

    html = render(socket)
    assert length(Regex.scan(~r/class="compare-node-value/, html)) == 2
    assert html =~ ~r/<span class="muted small">\s*ETS tables size\s*<\/span>/
  end

  test "the node whose value is above the lowest of the others is marked", ctx do
    socket =
      mount([entry(ctx.first, ctx.node), entry(ctx.second, ctx.other)])
      |> tick()
      |> finish_read(ctx.first)
      |> finish_read(ctx.second)
      |> with_raw(ctx.first, %{ets: 5_000_000, binary: 1})
      |> with_raw(ctx.second, %{ets: 1_000, binary: 1})
      |> event("metric", %{"metric" => "ets"})

    html = render(socket)
    assert html =~ ~s(class="compare-node-value metric-higher")
    assert html =~ ~s(class="compare-node-value")
    assert html =~ Format.bytes(5_000_000)
    assert html =~ Format.bytes(1_000)
  end

  defp with_raw(socket, server, raw) do
    columns = Map.update!(socket.assigns.columns, server, &Map.put(&1, :raw_memory, raw))
    Phoenix.Component.assign(socket, :columns, columns)
  end

  test "a metric name the page does not offer is ignored", ctx do
    socket =
      mount([entry(ctx.first, ctx.node), entry(ctx.second, ctx.other)])
      |> event("metric", %{"metric" => "no_such_metric"})

    assert socket.assigns.metric == :memory
  end
end
