defmodule Beamdash.MemoryRefreshTest do
  use ExUnit.Case, async: true

  alias Beamdash.Memory
  alias BeamdashWeb.MemoryLive

  defp connected_socket do
    {:ok, socket} = MemoryLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
    Phoenix.Component.assign(socket, status: :connected, node: :fake@host)
  end

  test "a tick starts one snapshot read, and a tick while it runs is skipped" do
    {:noreply, socket} = MemoryLive.handle_info(:tick, connected_socket())
    assert MapSet.member?(socket.assigns.in_flight, :snapshot)

    {:noreply, again} = MemoryLive.handle_info(:tick, socket)
    assert again.assigns.in_flight == socket.assigns.in_flight
  end

  test "on a top-list tab the tick makes one combined read, not a snapshot and a top list" do
    socket = Phoenix.Component.assign(connected_socket(), tab: :processes)
    {:noreply, socket} = MemoryLive.handle_info(:tick, socket)

    assert MapSet.member?(socket.assigns.in_flight, :page)
    refute MapSet.member?(socket.assigns.in_flight, :snapshot)
    refute Enum.any?(socket.assigns.in_flight, &match?({:top, _}, &1))
  end

  test "an error from the node is shown and clears the read" do
    socket = Phoenix.Component.assign(connected_socket(), in_flight: MapSet.new([:snapshot]))

    {:noreply, socket} =
      MemoryLive.handle_async({:memory, :snapshot}, {:ok, {:fake@host, {:error, :boom}}}, socket)

    refute MapSet.member?(socket.assigns.in_flight, :snapshot)
    assert socket.assigns.error
  end

  test "a read finished for a node that is no longer connected is dropped, and keeps the flag" do
    socket = Phoenix.Component.assign(connected_socket(), in_flight: MapSet.new([:snapshot]))

    {:noreply, socket} =
      MemoryLive.handle_async({:memory, :snapshot}, {:ok, {:other@host, {:error, :boom}}}, socket)

    assert MapSet.member?(socket.assigns.in_flight, :snapshot)
    assert socket.assigns.error == nil
  end

  test "a crashed read clears its flag" do
    socket = Phoenix.Component.assign(connected_socket(), in_flight: MapSet.new([:snapshot]))

    {:noreply, socket} = MemoryLive.handle_async({:memory, :snapshot}, {:exit, :boom}, socket)

    refute MapSet.member?(socket.assigns.in_flight, :snapshot)
  end

  test "top processes for an attribute the page no longer shows are dropped" do
    socket = connected_socket()

    {:noreply, socket} =
      MemoryLive.handle_async(
        {:memory, {:top, :reductions}},
        {:ok, {:fake@host, {:ok, {:processes, []}}}},
        socket
      )

    assert socket.assigns.top == nil
  end

  test "a second GC all while one runs starts nothing" do
    socket = Phoenix.Component.assign(connected_socket(), busy: :gc)

    assert {:noreply, ^socket} = MemoryLive.handle_event("gc_all", %{}, socket)
  end

  test "a second binary leak search while one runs starts nothing" do
    socket =
      Phoenix.Component.assign(%{connected_socket() | transport_pid: self()}, busy: :bin_leak)

    assert {:noreply, ^socket} = MemoryLive.handle_event("bin_leak", %{}, socket)
  end

  test "a GC all result from an earlier node clears the busy flag" do
    socket = Phoenix.Component.assign(connected_socket(), busy: :gc)

    {:noreply, socket} =
      MemoryLive.handle_async({:memory_action, :gc_all}, {:ok, {:other@host, :done}}, socket)

    assert socket.assigns.busy == nil
  end

  test "GC all is refused while not connected" do
    socket = Phoenix.Component.assign(connected_socket(), status: :disconnected)

    {:noreply, socket} = MemoryLive.handle_event("gc_all", %{}, socket)

    assert socket.assigns.busy == nil
  end

  test "a disconnect forgets the reads and the GC all that were running" do
    socket =
      Phoenix.Component.assign(connected_socket(), busy: :gc, in_flight: MapSet.new([:snapshot]))

    {:noreply, socket} =
      MemoryLive.handle_info({:beamdash_target, {:disconnected, :fake@host}}, socket)

    assert socket.assigns.busy == nil
    assert socket.assigns.in_flight == MapSet.new()
  end

  test "connecting to another node clears a GC all still running on the old one" do
    socket = Phoenix.Component.assign(connected_socket(), busy: :gc)

    {:noreply, socket} =
      MemoryLive.handle_info({:beamdash_target, {:connected, :other@host}}, socket)

    assert socket.assigns.busy == nil
  end

  defp browsing(result \\ nil) do
    browse = %{
      table: :tab,
      label: "tab",
      key: "",
      spec: "",
      rows: 500,
      result: result,
      examples: nil,
      key_pick: 0,
      spec_pick: 0,
      view: :raw,
      output: %{segments: [], pairs: []}
    }

    Phoenix.Component.assign(connected_socket(),
      ets: [%{id: :tab, name: :tab, named: true}],
      ets_browse: browse
    )
  end

  test "opening a table's browse finds it by its id" do
    {:noreply, socket} = MemoryLive.handle_event("ets_open", %{"id" => ":tab"}, browsing())
    assert %{table: :tab, label: "tab"} = socket.assigns.ets_browse

    {:noreply, socket} = MemoryLive.handle_event("ets_open", %{"id" => ":nope"}, socket)
    assert socket.assigns.ets_browse.table == :tab
  end

  test "a table's browse replaces the process panel in the same side column" do
    socket = Phoenix.Component.assign(browsing(), inspect: %{pid: self()})

    {:noreply, socket} = MemoryLive.handle_event("ets_open", %{"id" => ":tab"}, socket)
    assert socket.assigns.inspect == nil
  end

  test "a key that is not an Erlang term is refused without a read" do
    params = %{"mode" => "lookup", "key" => "1 +", "spec" => ""}
    {:noreply, socket} = MemoryLive.handle_event("ets_run", params, browsing())

    assert {:error, msg} = socket.assigns.ets_browse.result
    assert msg =~ "Erlang term"
  end

  test "the rows field is kept between 1 and 5000, and a bad value falls back to 1" do
    params = %{"mode" => "lookup", "key" => "1 +", "spec" => "", "rows" => "99999"}
    {:noreply, socket} = MemoryLive.handle_event("ets_run", params, browsing())
    assert socket.assigns.ets_browse.rows == 5_000

    params = Map.put(params, "rows", "0")
    {:noreply, socket} = MemoryLive.handle_event("ets_run", params, socket)
    assert socket.assigns.ets_browse.rows == 1

    params = Map.put(params, "rows", "many")
    {:noreply, socket} = MemoryLive.handle_event("ets_run", params, socket)
    assert socket.assigns.ets_browse.rows == 1
  end

  test "a browse result from the table and node being browsed is shown" do
    result = {:ok, %{rows: [{1, :a}], stop: :complete, keypos: 1}}

    {:noreply, socket} =
      MemoryLive.handle_async(:ets_browse, {:ok, {:fake@host, :tab, result}}, browsing())

    assert socket.assigns.ets_browse.result ==
             {:ok, %{rows: [{1, :a}], stop: :complete, keypos: 1}}
  end

  test "the output switches between raw and table, and an unknown view falls back to raw" do
    {:noreply, socket} = MemoryLive.handle_event("ets_view", %{"view" => "table"}, browsing())
    assert socket.assigns.ets_browse.view == :table

    {:noreply, socket} = MemoryLive.handle_event("ets_view", %{"view" => "pretty"}, socket)
    assert socket.assigns.ets_browse.view == :pretty

    {:noreply, socket} = MemoryLive.handle_event("ets_view", %{"view" => "raw"}, socket)
    assert socket.assigns.ets_browse.view == :raw

    {:noreply, socket} = MemoryLive.handle_event("ets_view", %{"view" => "other"}, socket)
    assert socket.assigns.ets_browse.view == :raw
  end

  test "the value after a secret-looking name is hidden in browse rows, others are shown" do
    rows = [
      {:shared_secret, "abc"},
      {:replicas, 2},
      {%{api_token: "xyz", size: 3}, :ok},
      [db_password: "p"]
    ]

    result = {:ok, %{rows: rows, stop: :complete, keypos: 1}}

    {:noreply, socket} =
      MemoryLive.handle_async(:ets_browse, {:ok, {:fake@host, :tab, result}}, browsing())

    assert {:ok, %{rows: [secret, replicas, nested, listed]}} = socket.assigns.ets_browse.result
    assert secret == {:shared_secret, "***"}
    assert replicas == {:replicas, 2}
    assert nested == {%{api_token: "***", size: 3}, :ok}
    assert listed == [db_password: "***"]
  end

  test "a refused browse shows why, in words" do
    {:noreply, socket} =
      MemoryLive.handle_async(
        :ets_browse,
        {:ok, {:fake@host, :tab, {:ok, {:error, :badarg}}}},
        browsing()
      )

    assert {:error, msg} = socket.assigns.ets_browse.result
    assert msg =~ "match spec"
  end

  test "examples of the table being browsed are built into keys and match specs" do
    result = {:ok, %{keypos: 1, arity: 2, keys: [1, :a]}}

    {:noreply, socket} =
      MemoryLive.handle_async(:ets_examples, {:ok, {:fake@host, :tab, result}}, browsing())

    assert {:ok, %{keys: ["1", "a"], specs: specs}} = socket.assigns.ets_browse.examples

    assert specs == [
             {"[{'_', [], ['$_']}]", "All rows, with no filter."},
             {"[{{1, '_'}, [], ['$_']}]", "Only the row whose key is 1."},
             {"[{{'$1', '_'}, [{'>', '$1', 1}], ['$_']}]", "Whole rows whose key is above 1."},
             {"[{{'$1', '_'}, [{'=<', '$1', 1}], ['$_']}]", "Whole rows whose key is at most 1."}
           ]
  end

  test "a table with atom keys gets sample match specs that filter by key type and value" do
    result = {:ok, %{keypos: 1, arity: 2, keys: [:a, :b]}}

    {:noreply, socket} =
      MemoryLive.handle_async(:ets_examples, {:ok, {:fake@host, :tab, result}}, browsing())

    assert {:ok, %{keys: ["a", "b"], specs: specs}} = socket.assigns.ets_browse.examples

    assert specs == [
             {"[{'_', [], ['$_']}]", "All rows, with no filter."},
             {"[{{a, '_'}, [], ['$_']}]", "Only the row whose key is a."},
             {"[{{'$1', '_'}, [{is_atom, '$1'}], ['$_']}]", "Whole rows whose key is an atom."}
           ]
  end

  test "every sample match spec runs against a table of the kind it was sampled from" do
    keys = [
      [1, 2, 3],
      [:a, :b],
      ["x", "yy"],
      [{1}, {1, 2}]
    ]

    for key_list <- keys do
      result = {:ok, %{keypos: 1, arity: 2, keys: key_list}}

      {:noreply, socket} =
        MemoryLive.handle_async(:ets_examples, {:ok, {:fake@host, :tab, result}}, browsing())

      {:ok, %{specs: specs}} = socket.assigns.ets_browse.examples
      assert specs != []

      tab = :ets.new(:sample_specs, [:set])
      Enum.each(key_list, &:ets.insert(tab, {&1, :value}))

      for {text, _description} <- specs do
        assert {:ok, term} = Memory.parse_term(text)
        assert is_list(:ets.select(tab, term)), "sample did not run: #{text}"
      end

      :ets.delete(tab)
    end
  end

  test "the sample for an existing key selects exactly that row" do
    for key <- [7, :a, "x", {1, 2}] do
      result = {:ok, %{keypos: 1, arity: 2, keys: [key]}}

      {:noreply, socket} =
        MemoryLive.handle_async(:ets_examples, {:ok, {:fake@host, :tab, result}}, browsing())

      {:ok, %{specs: [_all, {text, _description} | _]}} = socket.assigns.ets_browse.examples

      tab = :ets.new(:exact_key_sample, [:set])
      :ets.insert(tab, [{key, :v}, {:zz_not_sampled, :w}])

      assert {:ok, term} = Memory.parse_term(text)
      assert :ets.select(tab, term) == [{key, :v}]
      :ets.delete(tab)
    end
  end

  test "a failed examples read shows why" do
    {:noreply, socket} =
      MemoryLive.handle_async(
        :ets_examples,
        {:ok, {:fake@host, :tab, {:ok, {:error, :no_table}}}},
        browsing()
      )

    assert socket.assigns.ets_browse.examples == {:error, "This table is gone."}
  end

  test "examples from another node are dropped" do
    {:noreply, socket} =
      MemoryLive.handle_async(
        :ets_examples,
        {:ok, {:other@host, :tab, {:ok, %{keypos: 1, arity: 2, keys: [1]}}}},
        browsing()
      )

    assert socket.assigns.ets_browse.examples == nil
  end

  test "picking an example fills its field and bumps its counter, a bad index changes nothing" do
    examples = {:ok, %{keys: ["1"], specs: [{"a", "first"}, {"b", "second"}]}}
    socket = browsing()

    socket =
      Phoenix.Component.assign(socket,
        ets_browse: %{socket.assigns.ets_browse | examples: examples}
      )

    {:noreply, socket} =
      MemoryLive.handle_event("ets_pick", %{"kind" => "spec", "index" => "1"}, socket)

    assert %{spec: "b", spec_pick: 1} = socket.assigns.ets_browse

    {:noreply, socket} =
      MemoryLive.handle_event("ets_pick", %{"kind" => "key", "index" => "0"}, socket)

    assert %{key: "1", key_pick: 1} = socket.assigns.ets_browse

    {:noreply, socket} =
      MemoryLive.handle_event("ets_pick", %{"kind" => "key", "index" => "9"}, socket)

    assert socket.assigns.ets_browse.key == "1"
    assert socket.assigns.ets_browse.key_pick == 1
  end

  test "a browse result from another node is dropped" do
    {:noreply, socket} =
      MemoryLive.handle_async(
        :ets_browse,
        {:ok, {:other@host, :tab, {:ok, %{rows: [], stop: :complete}}}},
        browsing()
      )

    assert socket.assigns.ets_browse.result == nil
  end
end
