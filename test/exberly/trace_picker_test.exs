defmodule Exberly.TracePickerTest do
  # Picking several functions on the Tracing tab, as on the Profile tab,
  # and tracing them all at once against a real node.
  use ExUnit.Case, async: false

  alias Exberly.{SeqTracer, Target, Tracer}
  alias Exberly.Test.Fixture
  alias ExberlyWeb.{SeqLive, TraceLive}

  defp html(socket),
    do: TraceLive.render(socket.assigns) |> Phoenix.LiveViewTest.rendered_to_string()

  defp event(socket, name, params \\ %{}) do
    {:noreply, socket} = TraceLive.handle_event(name, params, socket)
    socket
  end

  defp seq_socket do
    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = SeqLive.mount(%{}, %{}, socket)

    Phoenix.Component.assign(socket,
      syntax: :erlang,
      status: :connected,
      traces: SeqTracer.traces()
    )
  end

  defp seq_html(socket),
    do: SeqLive.render(socket.assigns) |> Phoenix.LiveViewTest.rendered_to_string()

  defp pick(socket, fun, arity),
    do: event(socket, "select_function", %{"fun" => fun, "arity" => to_string(arity)})

  test "clicking functions picks and unpicks them" do
    assert TraceLive.toggle_pick([], {:m, :a, 1}) == [{:m, :a, 1}]
    assert TraceLive.toggle_pick([{:m, :a, 1}, {:m, :b, 0}], {:m, :a, 1}) == [{:m, :b, 0}]
  end

  describe "against a node" do
    setup do
      {peer, node} = Fixture.start_peer()
      {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie())
      :ok = Fixture.load(node)

      on_exit(fn ->
        Tracer.stop_all()
        Target.disconnect()
        Fixture.stop_peer(peer)
      end)

      socket = %Phoenix.LiveView.Socket{
        private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
      }

      {:ok, socket} = TraceLive.mount(%{}, %{}, socket)
      {:ok, modules} = Tracer.module_functions()

      socket =
        Phoenix.Component.assign(socket,
          syntax: :erlang,
          status: :connected,
          node: node,
          modules: modules
        )

      %{socket: event(socket, "select_module", %{"mod" => "exberly_fixture"}), node: node}
    end

    test "several picked functions are traced, seq traced and stopped together", %{
      socket: s,
      node: node
    } do
      assert html(s) =~ "Trace all"
      s = s |> pick("add", 2) |> pick("total", 1) |> pick("boom", 1) |> pick("boom", 1)
      assert s.assigns.picked == [{:exberly_fixture, :add, 2}, {:exberly_fixture, :total, 1}]
      h = html(s)
      # the picks show only as selected rows, not listed again
      refute h =~ "Picked 2"
      refute h =~ ~s(phx-click="unpick")
      assert h =~ ~s(id="trace-picked-clear")
      assert h =~ "Trace 2 functions"
      assert h =~ "calls each"
      assert h =~ "Pick one function for its call graph"
      refute h =~ "Trace all"
      # the module list marks where picks are
      assert h =~ ~r/class="selected has-picks"/

      s = event(s, "trace_picked", %{"limit" => ""})
      assert Tracer.traces() == [{:exberly_fixture, :add, 2}, {:exberly_fixture, :total, 1}]
      assert s.assigns.error == nil
      h = html(s)
      assert h =~ "Stop 2 traces"
      refute h =~ "Trace 2 functions"

      # a third pick: only it is still to start, with a limit
      s = pick(s, "spin", 1)
      assert html(s) =~ ~s(id="trace-picked-start")
      s = event(s, "trace_picked", %{"limit" => "5"})
      assert {:exberly_fixture, :spin, 1} in Tracer.traces()
      assert Tracer.limits()[{:exberly_fixture, :spin, 1}] == 5
      :erpc.call(node, :exberly_fixture, :total, [[1, 2]])

      s = event(s, "toggle_seq_trace")
      assert length(SeqTracer.traces()) == 3
      assert html(s) =~ "Stop seq traces"
      s = event(s, "toggle_seq_trace")
      assert SeqTracer.traces() == []

      # the Seq trace tab stops every seq trace at once
      s = event(s, "toggle_seq_trace")
      assert length(SeqTracer.traces()) == 3
      seq = seq_socket()
      assert seq_html(seq) =~ ~s(id="seq-stop-all")
      {:noreply, seq} = SeqLive.handle_event("stop_all", %{}, seq)
      assert SeqTracer.traces() == []
      assert seq.assigns.traces == []
      refute seq_html(seq) =~ ~s(id="seq-stop-all")
      assert :ok = SeqTracer.stop_all()
      {:noreply, s} = TraceLive.handle_info({:exberly_seq, :traces_changed}, s)
      assert html(s) =~ ~r/>\s*Seq trace\s*</

      s = event(s, "stop_picked")
      assert Tracer.traces() == []
      # clicking a selected row unpicks it
      s = pick(s, "add", 2)
      assert length(s.assigns.picked) == 2
      s = event(s, "unpick_all")
      assert s.assigns.picked == []
      assert html(s) =~ "Trace all"
    end

    test "one pick offers the call graph; Enter picks the first match", %{socket: s} do
      s = event(s, "pick_first_function", %{"fq" => "tot"})
      assert s.assigns.picked == [{:exberly_fixture, :total, 1}]
      h = html(s)
      assert h =~ "Call graph"
      assert h =~ ~r/id="trace-picked-start">\s*Trace\s*</
      refute h =~ ~s(id="trace-picked-clear")
      # picks persist across modules; the module list marks where they are
      s = event(s, "select_module", %{"mod" => "lists"})
      assert s.assigns.picked == [{:exberly_fixture, :total, 1}]
      assert html(s) =~ ~r/class=" has-picks"|class="has-picks"/
    end
  end
end
