defmodule Beamdash.TopProcessesTest do
  use ExUnit.Case, async: true

  alias BeamdashWeb.HomeLive

  test "CPU ranking is unavailable when sampling stops or fails" do
    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = HomeLive.mount(%{}, %{}, socket)
    {:noreply, socket} = HomeLive.handle_event("top_metric", %{"metric" => "cpu"}, socket)
    assert socket.assigns.sort_by == :reductions

    socket = Phoenix.Component.assign(socket, cpu_enabled: true)
    {:noreply, socket} = HomeLive.handle_event("top_metric", %{"metric" => "cpu"}, socket)
    assert socket.assigns.sort_by == :cpu
    {:noreply, socket} = HomeLive.handle_event("stop_cpu", %{}, socket)
    assert socket.assigns.sort_by == :reductions

    request = {:cpu_sample, make_ref()}

    socket =
      Phoenix.Component.assign(socket, cpu_enabled: true, cpu_request: request, sort_by: :cpu)

    {:noreply, socket} = HomeLive.handle_async(request, {:ok, {:error, :busy}}, socket)
    assert socket.assigns.sort_by == :reductions
    refute socket.assigns.cpu_enabled
  end

  test "filters by status before ranking and combines with text search" do
    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = HomeLive.mount(%{}, %{}, socket)

    procs =
      for n <- 1..12 do
        %{
          pid: :c.pid(0, n, 0),
          registered_name: String.to_atom("status_proc_#{n}"),
          initial_call: nil,
          current_function: nil,
          status: if(n > 10, do: :running, else: :waiting),
          message_queue_len: 0,
          memory: 100,
          reductions: 13 - n
        }
      end

    socket = Phoenix.Component.assign(socket, syntax: :erlang, status: :connected, procs: procs)
    {:noreply, socket} = HomeLive.handle_event("top_limit", %{"limit" => "10"}, socket)
    {:noreply, socket} = HomeLive.handle_event("filter_status", %{"status" => "running"}, socket)
    html = socket.assigns |> HomeLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "status_proc_11"
    assert html =~ "status_proc_12"
    refute html =~ ~r/status_proc_1\b/
    assert html =~ "2 of 12"

    {:noreply, socket} = HomeLive.handle_event("filter", %{"q" => "status_proc_11"}, socket)
    html = socket.assigns |> HomeLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "status_proc_11"
    refute html =~ "status_proc_12"
    assert html =~ "1 of 12"

    {:noreply, unchanged} =
      HomeLive.handle_event("filter_status", %{"status" => "invalid"}, socket)

    assert unchanged.assigns.status_filter == MapSet.new(["running"])
    {:noreply, socket} = HomeLive.handle_event("filter", %{"q" => ""}, socket)
    {:noreply, socket} = HomeLive.handle_event("filter_status", %{"status" => "waiting"}, socket)
    html = socket.assigns |> HomeLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "12 of 12"
    assert socket.assigns.status_filter == MapSet.new(["running", "waiting"])
    {:noreply, socket} = HomeLive.handle_event("filter_status", %{"status" => "running"}, socket)
    html = socket.assigns |> HomeLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "10 of 12"
    refute html =~ "status_proc_11"
    {:noreply, socket} = HomeLive.handle_event("filter_status", %{"status" => "all"}, socket)
    html = socket.assigns |> HomeLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "12 of 12"
  end

  test "the CPU table column is visible only while sampling is enabled" do
    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = HomeLive.mount(%{}, %{}, socket)
    socket = Phoenix.Component.assign(socket, syntax: :erlang, status: :connected, procs: [])
    html = socket.assigns |> HomeLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    refute html =~ ~s(phx-value-col="cpu")
    assert html =~ ~s(colspan="8")

    socket = Phoenix.Component.assign(socket, cpu_enabled: true)
    html = socket.assigns |> HomeLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ ~s(phx-value-col="cpu")
    assert html =~ ~s(colspan="9")

    {:noreply, socket} = HomeLive.handle_event("stop_cpu", %{}, socket)
    html = socket.assigns |> HomeLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    refute html =~ ~s(phx-value-col="cpu")
    assert html =~ ~s(colspan="8")

    pid = :c.pid(0, 29, 0)

    process = %{
      pid: pid,
      registered_name: :test_cpu_row,
      initial_call: nil,
      current_function: nil,
      status: :waiting,
      message_queue_len: 0,
      memory: 100,
      reductions: 10
    }

    socket = Phoenix.Component.assign(socket, procs: [process], cpu_values: %{pid => 42.0})
    html = socket.assigns |> HomeLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    refute html =~ "42.0%"
    socket = Phoenix.Component.assign(socket, cpu_enabled: true)
    html = socket.assigns |> HomeLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "42.0%"
  end

  test "the process table exposes keyboard-accessible sort controls and an empty state" do
    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = HomeLive.mount(%{}, %{}, socket)
    socket = Phoenix.Component.assign(socket, syntax: :erlang, status: :connected, procs: [])
    html = socket.assigns |> HomeLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ ~r/<button[^>]*phx-click="sort"[^>]*phx-value-col="memory"/

    assert html =~
             ~r/<th[^>]*aria-sort="descending"[^>]*>\s*<button[^>]*phx-click="sort"[^>]*phx-value-col="reductions"/

    assert html =~ "No processes match the current filters"
    assert html =~ ~s(aria-label="Search processes")
    {:noreply, socket} = HomeLive.handle_event("sort", %{"col" => "name"}, socket)
    html = socket.assigns |> HomeLive.render() |> Phoenix.LiveViewTest.rendered_to_string()

    assert html =~
             ~r/<th[^>]*aria-sort="ascending"[^>]*>\s*<button[^>]*phx-click="sort"[^>]*phx-value-col="name"/
  end

  test "CPU sampling repeats until stopped and clears the displayed sample" do
    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = HomeLive.mount(%{}, %{}, socket)
    request = {:cpu_sample, make_ref()}
    generation = make_ref()

    socket =
      Phoenix.Component.assign(socket,
        status: :connected,
        node: :target,
        cpu_enabled: true,
        cpu_generation: generation,
        cpu_request: request
      )

    {:noreply, socket} = HomeLive.handle_async(request, {:ok, {:ok, %{self() => 42.0}}}, socket)
    assert socket.assigns.cpu_values[self()] == 42.0
    assert_receive {:cpu_tick, ^generation}, 2_500
    {:noreply, socket} = HomeLive.handle_event("stop_cpu", %{}, socket)
    refute socket.assigns.cpu_enabled
    assert socket.assigns.cpu_values == %{}
    {:noreply, unchanged} = HomeLive.handle_info({:cpu_tick, generation}, socket)
    assert unchanged.assigns.cpu_request == nil
  end

  test "ignores CPU results after the target changes" do
    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = HomeLive.mount(%{}, %{}, socket)
    request = {:cpu_sample, make_ref()}

    socket =
      Phoenix.Component.assign(socket, status: :connected, node: :old, cpu_request: request)

    {:noreply, socket} =
      HomeLive.handle_info({:beamdash_target, {:disconnected, :nodedown}}, socket)

    {:noreply, socket} = HomeLive.handle_async(request, {:ok, {:ok, %{self() => 100.0}}}, socket)
    assert socket.assigns.cpu_values == %{}
    refute socket.assigns.cpu_sampled
  end

  test "sorts measured CPU percentages and leaves missing samples last" do
    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = HomeLive.mount(%{}, %{}, socket)
    pids = for n <- 20..22, do: :c.pid(0, n, 0)

    procs =
      for {pid, n} <- Enum.with_index(pids) do
        %{
          pid: pid,
          registered_name: Enum.at([:cpu_first, :cpu_second, :cpu_unknown], n),
          initial_call: nil,
          current_function: nil,
          status: :waiting,
          message_queue_len: 0,
          memory: 1000,
          reductions: 100
        }
      end

    socket =
      Phoenix.Component.assign(socket,
        syntax: :erlang,
        status: :connected,
        node: :sample_node,
        procs: procs,
        cpu_enabled: true,
        cpu_values: %{Enum.at(pids, 0) => 20.0, Enum.at(pids, 1) => 70.0}
      )

    {:noreply, socket} = HomeLive.handle_event("top_metric", %{"metric" => "cpu"}, socket)
    html = socket.assigns |> HomeLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "CPU %"
    assert html =~ "70.0%"
    assert elem(:binary.match(html, "cpu_second"), 0) < elem(:binary.match(html, "cpu_first"), 0)
    assert elem(:binary.match(html, "cpu_first"), 0) < elem(:binary.match(html, "cpu_unknown"), 0)

    {:noreply, socket} = HomeLive.handle_event("sort", %{"col" => "cpu"}, socket)
    html = socket.assigns |> HomeLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert elem(:binary.match(html, "cpu_first"), 0) < elem(:binary.match(html, "cpu_second"), 0)

    assert elem(:binary.match(html, "cpu_second"), 0) <
             elem(:binary.match(html, "cpu_unknown"), 0)
  end

  test "ranks processes by the chosen metric and limits the results" do
    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = HomeLive.mount(%{}, %{}, socket)

    procs =
      for n <- 1..12 do
        %{
          pid: :c.pid(0, n, 0),
          registered_name: String.to_atom("ranked_proc_#{n}"),
          initial_call: nil,
          current_function: nil,
          status: :waiting,
          message_queue_len: n,
          memory: n * 1_000,
          reductions: (13 - n) * 100
        }
      end

    rates = Map.new(Enum.with_index(procs, 1), fn {p, n} -> {p.pid, n * 10} end)

    socket =
      Phoenix.Component.assign(socket,
        syntax: :erlang,
        status: :connected,
        procs: procs,
        rates: rates
      )

    {:noreply, socket} = HomeLive.handle_event("top_metric", %{"metric" => "rate"}, socket)
    {:noreply, socket} = HomeLive.handle_event("top_limit", %{"limit" => "10"}, socket)
    html = socket.assigns |> HomeLive.render() |> Phoenix.LiveViewTest.rendered_to_string()

    assert html =~ "ranked_proc_12"
    refute html =~ ~r/ranked_proc_1\b/
    assert html =~ "showing first 10"
    assert socket.assigns.sort_by == :reds_per_sec
    assert socket.assigns.sort_dir == :desc

    {:noreply, socket} = HomeLive.handle_event("top_metric", %{"metric" => "reductions"}, socket)
    html = socket.assigns |> HomeLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ ~r/ranked_proc_1\b/
    refute html =~ ~r/ranked_proc_12\b/

    for metric <- ["memory", "mq"] do
      {:noreply, ranked} = HomeLive.handle_event("top_metric", %{"metric" => metric}, socket)
      html = ranked.assigns |> HomeLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
      assert html =~ ~r/ranked_proc_12\b/
      refute html =~ ~r/ranked_proc_1\b/
    end

    {:noreply, same} = HomeLive.handle_event("top_limit", %{"limit" => "999999"}, socket)
    assert same.assigns.row_limit == 10
  end
end
