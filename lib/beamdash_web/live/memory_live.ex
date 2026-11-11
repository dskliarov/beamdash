defmodule BeamdashWeb.MemoryLive do
  @moduledoc """
  Memory of the connected node: an `erlang:memory()` breakdown refreshed
  every 2 s with its trend, limits, and a leak investigation per kind of
  memory (processes, binaries, ETS), using recon where possible
  (`Beamdash.Memory`).
  """
  use Phoenix.LiveView

  alias Beamdash.{Format, Memory, MemoryAdvisor, MemoryHistory, Settings, Store, Target}

  import BeamdashWeb.HelpTip, only: [tip: 1]

  @refresh_ms 2_000
  # 5 minutes of 2 s samples
  @history 150
  @trend_history 301
  @ets_refresh_ms 5_000
  @browse_rows 1
  @empty_output %{segments: [], pairs: []}
  @browse_max_rows 5_000
  @browse_ms 2_000
  @example_rows 5
  @trend_windows [30, 60, 120, 300, 600]
  @stored_windows [{900, "15 min"}, {3_600, "1 h"}, {21_600, "6 h"}, {86_400, "24 h"}]
  @stored_points 1_000
  @stored_rows 200

  # The parts erlang:memory() splits `total` into, in this (fixed) order;
  # each has its own colour (see app.css, --mem-*).
  @parts [
    processes: "Processes",
    binary: "Binaries",
    ets: "ETS",
    code: "Code",
    atom: "Atoms",
    other: "Other system"
  ]

  @attrs [
    memory: "Memory",
    message_queue_len: "Message queue",
    binary_memory: "Binary memory",
    reductions: "Reductions"
  ]

  @impl true
  def mount(_params, _session, socket) do
    %{status: status, node: node} = Target.status()

    socket =
      assign(socket,
        jev_backend: Beamdash.Jev.backend(),
        status: status,
        node: node,
        snap: nil,
        history: [],
        trend_history: [],
        visible_trends: MapSet.new(Keyword.keys(@parts)),
        trend_window: 300,
        # stored samples, from Beamdash.Store: nil until the History page is opened
        stored_window: 3_600,
        stored: nil,
        recon: nil,
        error: nil,
        page: :leak,
        tab: nil,
        attr: :memory,
        top_n: 10,
        top: nil,
        top_prev: %{},
        gc: nil,
        leaks: nil,
        busy: nil,
        ets: nil,
        ets_base: %{},
        ets_prev: %{},
        ets_sort: {:memory, :desc},
        ets_filter: "",
        ets_browse: nil,
        inspect: nil,
        # Nx: where memory and the limits are heading
        forecast: nil,
        # Jev: which kind of memory needs attention
        health: %{request: nil, advice: nil, error: nil, evidence: nil},
        # ?check=1: run the health check as soon as there is enough history
        health_auto: false,
        in_flight: MapSet.new()
      )

    if connected?(socket) do
      :ok = Target.subscribe()
      Process.send_after(self(), :tick, @refresh_ms)
      Process.send_after(self(), :ets_tick, @ets_refresh_ms)
      if status == :connected, do: send(self(), :start)
      {:ok, socket}
    else
      {:ok, socket}
    end
  end

  defp start(socket) do
    socket
    |> request_recon()
    |> request_snapshot()
    |> load_tab()
  end

  defp working(%{busy: :gc}), do: "Collecting garbage on every process"
  defp working(%{busy: :bin_leak}), do: "Finding binary leaks"

  defp working(%{in_flight: in_flight}) do
    if MapSet.size(in_flight) > 0, do: "Reading memory from the node"
  end

  ## Data

  # Each read of the node runs in a task, so a slow node never holds up
  # events; a read that is still running is not started again.
  defp fetch(socket, kind, read) do
    if MapSet.member?(socket.assigns.in_flight, kind) do
      socket
    else
      node = socket.assigns.node

      socket
      |> assign(in_flight: MapSet.put(socket.assigns.in_flight, kind))
      |> start_async({:memory, kind}, fn -> {node, read.(node)} end)
    end
  end

  # Stops the reads and actions still running against the previous node.
  defp cancel_reads(socket) do
    socket.assigns.in_flight
    |> Enum.reduce(socket, &cancel_async(&2, {:memory, &1}))
    |> cancel_async({:memory_action, :gc_all})
    |> cancel_async({:memory_action, :bin_leak})
    |> cancel_async(:ets_browse)
    |> cancel_async(:ets_examples)
    |> assign(in_flight: MapSet.new(), busy: nil, ets_browse: nil)
  end

  defp request_recon(socket), do: fetch(socket, :recon, &Memory.recon_status/1)
  defp request_snapshot(socket), do: fetch(socket, :snapshot, &Memory.snapshot/1)
  defp request_ets(socket), do: fetch(socket, :ets, &Memory.ets_tables/1)

  # The snapshot and the open top list in one call; the ETS page and the
  # bare start only need the snapshot.
  defp request_refresh(%{assigns: %{tab: tab}} = socket) when tab in [nil, :ets],
    do: request_snapshot(socket)

  defp request_refresh(socket) do
    attr = top_attr(socket)
    top_n = socket.assigns.top_n
    fetch(socket, :page, &Memory.page(&1, attr, top_n))
  end

  defp request_top(socket) do
    attr = top_attr(socket)
    top_n = socket.assigns.top_n
    fetch(socket, {:top, attr}, &Memory.top_processes(&1, attr, top_n))
  end

  defp top_attr(%{assigns: %{tab: :binary}}), do: :binary_memory
  defp top_attr(socket), do: socket.assigns.attr

  defp apply_read(socket, :recon, recon), do: assign(socket, recon: recon)

  defp apply_read(socket, :snapshot, {:ok, snap}) do
    point = %{
      at: snap.sampled_at_ms,
      memory: snap.memory,
      counts: %{
        atom_count: snap.atom_count,
        process_count: snap.process_count,
        ets_count: snap.ets_count
      }
    }

    history = Enum.take(socket.assigns.history ++ [point], -@history)
    trend_history = Enum.take(socket.assigns.trend_history ++ [point], -@trend_history)

    socket =
      assign(socket,
        snap: snap,
        history: history,
        trend_history: trend_history,
        forecast: Beamdash.Insights.Forecast.forecast(history, snap),
        error: nil
      )

    if socket.assigns.tab == nil,
      do: socket |> assign(tab: suggested_tab(snap)) |> load_tab(),
      else: socket
  end

  defp apply_read(socket, :page, {:ok, {snap, top}}) do
    attr = top_attr(socket)

    socket
    |> apply_read(:snapshot, {:ok, snap})
    |> apply_read({:top, attr}, {:ok, top})
  end

  defp apply_read(socket, :ets, {:ok, tables}) do
    now = Map.new(tables, &{&1.id, &1})
    # growth is measured against the first time a table was seen here
    base = Map.merge(now, socket.assigns.ets_base, fn _id, _new, old -> old end)
    prev = socket.assigns.ets || []
    assign(socket, ets: tables, ets_base: base, ets_prev: Map.new(prev, &{&1.id, &1}), error: nil)
  end

  defp apply_read(socket, {:top, attr}, {:ok, {source, entries}}) do
    if attr == top_attr(socket) do
      prev =
        case socket.assigns.top do
          %{attr: ^attr, entries: old} -> Map.new(old, &{&1.pid, &1.value})
          _ -> %{}
        end

      assign(socket, top: %{attr: attr, source: source, entries: entries}, top_prev: prev)
    else
      socket
    end
  end

  defp apply_read(socket, _kind, {:error, reason}),
    do: assign(socket, error: Format.error(reason))

  defp apply_read(socket, _kind, _other), do: socket

  defp load_tab(%{assigns: %{tab: :ets}} = socket), do: request_ets(socket)
  defp load_tab(%{assigns: %{tab: nil}} = socket), do: socket
  defp load_tab(socket), do: request_top(socket)

  defp load_stored(%{assigns: %{page: :history}} = socket) do
    %{node: node, stored_window: window} = socket.assigns

    if Settings.snapshots_enabled?() and Process.whereis(Store) != nil do
      from = System.system_time(:millisecond) - window * 1_000
      rows = Store.query(:memory, node: to_string(node), from: from, limit: @stored_points)
      changes = rows |> Enum.reverse() |> MemoryHistory.changes()

      assign(socket,
        stored: %{
          enabled: true,
          from: from,
          points: changes,
          rows: changes |> Enum.reverse() |> Enum.take(@stored_rows),
          summary: MemoryHistory.summary(changes)
        }
      )
    else
      assign(socket, stored: %{enabled: false, rows: [], summary: nil})
    end
  end

  defp load_stored(socket), do: socket

  # the node's answer comes back through handle_async/3
  defp action(socket, kind, run) do
    node = socket.assigns.node
    start_async(socket, {:memory_action, kind}, fn -> {node, run.(node)} end)
  end

  defp browse_limit(text) do
    case Integer.parse(text || "") do
      {n, ""} -> n |> max(1) |> min(@browse_max_rows)
      _ -> @browse_rows
    end
  end

  defp browse_request("lookup", %{key: key, rows: rows}) do
    case Memory.parse_term(key) do
      {:ok, term} -> {:ok, &Memory.ets_lookup(&1, &2, term, rows)}
      {:error, msg} -> {:error, msg}
    end
  end

  defp browse_request("select", %{spec: spec, rows: rows}) do
    spec = if String.trim(spec) == "", do: "[{'_', [], ['$_']}]", else: spec

    case Memory.parse_term(spec) do
      {:ok, term} when is_list(term) ->
        {:ok, &Memory.ets_browse(&1, &2, term, rows, @browse_ms)}

      {:ok, _} ->
        {:error, "The match spec must be a list, like [{'_', [], ['$_']}]."}

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp browse_result({:ok, found}) when is_map(found), do: {:ok, found}
  defp browse_result({:ok, {:error, reason}}), do: {:error, browse_message(reason)}
  defp browse_result({:error, reason}), do: {:error, Format.error(reason)}

  defp browse_message(:no_table), do: "This table is gone."
  defp browse_message(:private), do: "This table is private: only its owner can read it."

  defp browse_message(:badarg),
    do: "The table could not be read: it may have been deleted, or the match spec is not valid."

  defp browse_message(other), do: Format.error(other)

  defp browse_rows({:ok, %{rows: rows} = found}),
    do: {:ok, %{found | rows: Enum.map(rows, &mask_secrets/1)}}

  defp browse_rows(result), do: result

  # a value right after a secret-looking name (tuple element or map key) is hidden
  @masked "***"

  defp mask_secrets(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> mask_items() |> List.to_tuple()

  defp mask_secrets(term) when is_map(term) do
    Map.new(:maps.to_list(term), fn {k, v} ->
      if secret_name?(k), do: {k, @masked}, else: {mask_secrets(k), mask_secrets(v)}
    end)
  end

  defp mask_secrets([head | tail]), do: [mask_secrets(head) | mask_secrets(tail)]
  defp mask_secrets(term), do: term

  defp mask_items([name, value | rest]) do
    if secret_name?(name),
      do: [mask_secrets(name), @masked | mask_items(rest)],
      else: [mask_secrets(name) | mask_items([value | rest])]
  end

  defp mask_items([last]), do: [mask_secrets(last)]
  defp mask_items([]), do: []

  defp secret_name?(name) when is_atom(name), do: secret_name?(Atom.to_string(name))

  defp secret_name?(name) when is_binary(name),
    do: Regex.match?(~r/secret|passw|token|credential|api_?key|private_?key/i, name)

  defp secret_name?(_name), do: false

  defp browse_summary(nil, _n), do: nil
  defp browse_summary(:complete, 0), do: "Nothing found."
  defp browse_summary(:complete, n), do: "Found #{Format.number(n)}."
  defp browse_summary(:rows, n), do: "First #{Format.number(n)} shown: more may match."

  defp browse_summary(:time, n),
    do:
      "Stopped after #{@browse_ms} ms with #{Format.number(n)} rows: narrow the match spec to see the rest."

  defp rows_segments(rows, syntax, view) do
    rows
    |> Enum.map(&pretty_segments(row_text(&1, syntax, view)))
    |> Enum.intersperse([{nil, "\n\n"}])
    |> Enum.concat()
  end

  # Format.term cuts lists after 20 elements; a huge width keeps the whole row on one line.
  defp row_text(row, syntax, :raw), do: Format.pretty(row, syntax, 1_000_000)
  defp row_text(row, syntax, :pretty), do: Format.pretty(row, syntax)

  defp key_value_rows(rows, keypos, syntax) do
    Enum.map(rows, fn row ->
      fields = if is_tuple(row), do: Tuple.to_list(row), else: [row]
      {key, rest} = List.pop_at(fields, keypos - 1)
      {pretty_segments(Format.pretty(key, syntax, 1)), value_segments(rest, syntax)}
    end)
  end

  defp value_segments([], _syntax), do: []
  defp value_segments([value], syntax), do: pretty_segments(Format.pretty(value, syntax, 1))

  defp value_segments(rest, syntax),
    do: pretty_segments(Format.pretty(List.to_tuple(rest), syntax, 1))

  defp put_output(
         %{
           assigns: %{
             syntax: syntax,
             ets_browse: %{result: {:ok, %{rows: rows, keypos: keypos}}} = browse
           }
         } =
           socket
       ) do
    assign(socket, ets_browse: %{browse | output: output(browse.view, rows, keypos, syntax)})
  end

  defp put_output(socket), do: socket

  defp output(:table, rows, keypos, syntax),
    do: %{segments: [], pairs: key_value_rows(rows, keypos, syntax)}

  defp output(view, rows, _keypos, syntax),
    do: %{segments: rows_segments(rows, syntax, view), pairs: []}

  # Quoted strings and atoms are kept whole, so braces inside them stay plain.
  defp pretty_segments(text) do
    ~r/("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[{}\[\](),])/
    |> Regex.split(text, include_captures: true)
    |> Enum.map(&{punct_class(&1), &1})
  end

  defp punct_class("{"), do: "tok-curly"
  defp punct_class("}"), do: "tok-curly"
  defp punct_class("["), do: "tok-square"
  defp punct_class("]"), do: "tok-square"
  defp punct_class("("), do: "tok-round"
  defp punct_class(")"), do: "tok-round"
  defp punct_class(","), do: "tok-comma"
  defp punct_class(_text), do: nil

  defp examples_result(result) do
    case browse_result(result) do
      {:ok, found} -> {:ok, browse_examples(found)}
      {:error, msg} -> {:error, msg}
    end
  end

  defp browse_examples(%{keys: keys, keypos: keypos, arity: arity}) do
    texts =
      keys
      |> Enum.map(&Format.term(&1, :erlang, 10_000))
      |> Enum.filter(&match?({:ok, _}, Memory.parse_term(&1)))

    %{keys: texts, specs: example_specs(keys, keypos, arity)}
  end

  defp example_specs(_keys, _keypos, nil), do: []

  defp example_specs(keys, keypos, arity) do
    all = {"[{'_', [], ['$_']}]", "All rows, with no filter."}
    [all | exact_key_spec(keys, keypos, arity) ++ key_specs(keys, keypos, arity)]
  end

  defp exact_key_spec([k | _], keypos, arity) do
    text = Format.term(k, :erlang, 10_000)

    case Memory.parse_term(text) do
      {:ok, _} ->
        [{"[{#{keyed(arity, keypos, text)}, [], ['$_']}]", "Only the row whose key is #{text}."}]

      {:error, _} ->
        []
    end
  end

  defp exact_key_spec([], _keypos, _arity), do: []

  defp key_specs(keys, keypos, arity) do
    case keys do
      [k | _] when is_integer(k) ->
        [
          {spec(arity, keypos, "{'>', '$1', #{k}}"), "Whole rows whose key is above #{k}."},
          {spec(arity, keypos, "{'=<', '$1', #{k}}"), "Whole rows whose key is at most #{k}."}
        ]

      [k | _] when is_atom(k) ->
        [{spec(arity, keypos, "{is_atom, '$1'}"), "Whole rows whose key is an atom."}]

      [k | _] when is_binary(k) ->
        [
          {spec(arity, keypos, "{is_binary, '$1'}"), "Whole rows whose key is a binary."},
          {spec(arity, keypos, "{'>', {byte_size, '$1'}, 8}"),
           "Whole rows whose key is longer than 8 bytes."}
        ]

      [k | _] when is_tuple(k) ->
        [
          {spec(arity, keypos, "{is_tuple, '$1'}"), "Whole rows whose key is a tuple."},
          {spec(arity, keypos, "{'=:=', {size, '$1'}, #{tuple_size(k)}}"),
           "Whole rows whose key is a tuple of #{tuple_size(k)} elements."}
        ]

      _ ->
        []
    end
  end

  defp spec(arity, keypos, guard),
    do: "[{#{keyed(arity, keypos, "'$1'")}, [#{guard}], ['$_']}]"

  defp keyed(arity, keypos, bind),
    do: "{" <> Enum.map_join(1..arity, ", ", &if(&1 == keypos, do: bind, else: "'_'")) <> "}"

  defp pick_example(browse, examples, "key", index) do
    with {i, ""} <- Integer.parse(index),
         {:ok, text} <- Enum.fetch(examples.keys, i) do
      {:ok, %{browse | key: text, key_pick: browse.key_pick + 1}}
    else
      _ -> :error
    end
  end

  defp pick_example(browse, examples, "spec", index) do
    with {i, ""} <- Integer.parse(index),
         {:ok, {text, _description}} <- Enum.fetch(examples.specs, i) do
      {:ok, %{browse | spec: text, spec_pick: browse.spec_pick + 1}}
    else
      _ -> :error
    end
  end

  defp pick_example(_browse, _examples, _kind, _index), do: :error

  defp apply_action(socket, :gc_all, {:ok, gc}),
    do: socket |> assign(gc: gc, busy: nil) |> request_refresh()

  defp apply_action(socket, :gc_all, {:error, r}),
    do: assign(socket, error: Format.error(r), busy: nil)

  defp apply_action(socket, :bin_leak, {:ok, leaks}),
    do: socket |> assign(leaks: leaks, busy: nil) |> request_refresh()

  defp apply_action(socket, :bin_leak, {:error, r}),
    do: assign(socket, error: Format.error(r), busy: nil)

  # The investigation to open first: the biggest of processes, binaries
  # and ETS.
  defp suggested_tab(%{memory: m}) do
    [processes: m.processes, binary: m.binary, ets: m.ets]
    |> Enum.max_by(&elem(&1, 1))
    |> elem(0)
  end

  # ?tab=processes|binary|ets and ?check=1 come from links ("Ask beamdash")
  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      case params["tab"] do
        tab when tab in ~w(processes binary ets) ->
          socket =
            assign(socket,
              page: :leak,
              tab: String.to_existing_atom(tab),
              inspect: nil,
              top: nil
            )

          if socket.assigns.status == :connected and connected?(socket),
            do: load_tab(socket),
            else: socket

        _ ->
          socket
      end

    {:noreply, if(params["check"] == "1", do: assign(socket, health_auto: true), else: socket)}
  end

  ## Events

  @impl true
  def handle_event("page", %{"page" => page}, socket) when page in ~w(forecast leak history) do
    {:noreply, socket |> assign(page: String.to_existing_atom(page)) |> load_stored()}
  end

  def handle_event("stored_window", %{"window" => window}, socket)
      when window in ~w(900 3600 21600 86400) do
    {:noreply, socket |> assign(stored_window: String.to_integer(window)) |> load_stored()}
  end

  def handle_event("tab", %{"tab" => tab}, socket) when tab in ~w(processes binary ets) do
    {:noreply,
     socket
     |> cancel_async(:ets_browse)
     |> cancel_async(:ets_examples)
     |> assign(
       page: :leak,
       tab: String.to_existing_atom(tab),
       inspect: nil,
       ets_browse: nil,
       top: nil
     )
     |> load_tab()}
  end

  def handle_event("toggle_trend", %{"kind" => kind}, socket) do
    case Enum.find(Keyword.keys(@parts), &(Atom.to_string(&1) == kind)) do
      nil ->
        {:noreply, socket}

      key ->
        visible = socket.assigns.visible_trends

        visible =
          if MapSet.member?(visible, key),
            do: MapSet.delete(visible, key),
            else: MapSet.put(visible, key)

        {:noreply, assign(socket, visible_trends: visible)}
    end
  end

  def handle_event("zoom_trend", %{"direction" => direction}, socket)
      when direction in ["in", "out"] do
    index = Enum.find_index(@trend_windows, &(&1 == socket.assigns.trend_window))

    next =
      if direction == "in",
        do: max(index - 1, 0),
        else: min(index + 1, length(@trend_windows) - 1)

    {:noreply, assign(socket, trend_window: Enum.at(@trend_windows, next))}
  end

  def handle_event("attr", %{"attr" => attr, "n" => n}, socket) do
    attr = Enum.find(Keyword.keys(@attrs), :memory, &(Atom.to_string(&1) == attr))
    n = if n in ~w(5 10 20 50), do: String.to_integer(n), else: 10
    {:noreply, socket |> assign(attr: attr, top_n: n, top: nil) |> request_top()}
  end

  def handle_event("refresh_top", _params, socket), do: {:noreply, request_top(socket)}

  def handle_event("gc_all", _params, %{assigns: %{status: :connected, busy: nil}} = socket),
    do: {:noreply, socket |> assign(busy: :gc) |> action(:gc_all, &Memory.gc_all/1)}

  def handle_event("gc_all", _params, socket), do: {:noreply, socket}

  def handle_event("bin_leak", _params, %{assigns: %{status: :connected, busy: nil}} = socket) do
    top_n = socket.assigns.top_n

    {:noreply,
     socket
     |> assign(busy: :bin_leak)
     |> action(:bin_leak, &Memory.binary_leaks(&1, top_n))}
  end

  def handle_event("bin_leak", _params, socket), do: {:noreply, socket}

  def handle_event("inspect", %{"pid" => pid_text}, socket) do
    with pid when is_pid(pid) <- Target.parse_pid(pid_text, socket.assigns.node),
         {:ok, %{} = state} <- Memory.process_state(socket.assigns.node, pid, false) do
      {:noreply, assign(socket, inspect: Map.put(state, :pid, pid), ets_browse: nil)}
    else
      {:ok, :undefined} ->
        {:noreply, assign(socket, inspect: nil, error: "The process has exited.")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("get_status", _params, %{assigns: %{inspect: %{pid: pid}}} = socket) do
    case Memory.process_state(socket.assigns.node, pid, true) do
      {:ok, %{} = state} ->
        {:noreply, assign(socket, inspect: Map.put(state, :pid, pid))}

      {:ok, :undefined} ->
        {:noreply, assign(socket, inspect: nil, error: "The process has exited.")}

      {:error, r} ->
        {:noreply, assign(socket, error: Format.error(r))}
    end
  end

  def handle_event("close_inspect", _params, socket), do: {:noreply, assign(socket, inspect: nil)}

  def handle_event(
        "analyze_memory",
        _params,
        %{assigns: %{snap: snap, health: %{request: nil}}} = socket
      )
      when is_map(snap) do
    if match?({:ready, _}, MemoryAdvisor.readiness(socket.assigns.history)) do
      {:noreply, start_health(socket)}
    else
      {:noreply,
       put_health(socket,
         error: "Keep this page open a little longer: history is still being collected."
       )}
    end
  end

  def handle_event("analyze_memory", _params, socket), do: {:noreply, socket}

  def handle_event("ets_sort", %{"col" => col}, socket) when col in ~w(name size memory growth) do
    col = String.to_existing_atom(col)

    dir =
      case socket.assigns.ets_sort do
        {^col, :desc} -> :asc
        {^col, :asc} -> :desc
        _ -> if col == :name, do: :asc, else: :desc
      end

    {:noreply, assign(socket, ets_sort: {col, dir})}
  end

  def handle_event("ets_filter", %{"q" => q}, socket),
    do: {:noreply, assign(socket, ets_filter: q)}

  def handle_event("ets_reset", _params, socket),
    do: {:noreply, assign(socket, ets_base: Map.new(socket.assigns.ets || [], &{&1.id, &1}))}

  def handle_event("ets_open", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.ets || [], &(inspect(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      table ->
        browse = %{
          table: table.id,
          label: table_name(table),
          key: "",
          spec: "",
          rows: @browse_rows,
          result: nil,
          examples: nil,
          key_pick: 0,
          spec_pick: 0,
          view: :raw,
          output: @empty_output
        }

        node = socket.assigns.node
        id = table.id

        {:noreply,
         socket
         |> cancel_async(:ets_browse)
         |> cancel_async(:ets_examples)
         |> start_async(:ets_examples, fn ->
           {node, id, Memory.ets_examples(node, id, @example_rows, @browse_ms)}
         end)
         |> assign(ets_browse: browse, inspect: nil)}
    end
  end

  def handle_event("ets_close", _params, socket),
    do:
      {:noreply,
       socket
       |> cancel_async(:ets_browse)
       |> cancel_async(:ets_examples)
       |> assign(ets_browse: nil)}

  def handle_event(
        "ets_run",
        %{"mode" => mode} = params,
        %{assigns: %{ets_browse: browse}} = socket
      )
      when browse != nil do
    browse = %{
      browse
      | key: params["key"] || "",
        spec: params["spec"] || "",
        rows: browse_limit(params["rows"])
    }

    case browse_request(mode, browse) do
      {:ok, read} ->
        node = socket.assigns.node
        table = browse.table

        {:noreply,
         socket
         |> assign(ets_browse: %{browse | result: nil, output: @empty_output})
         |> cancel_async(:ets_browse)
         |> start_async(:ets_browse, fn -> {node, table, read.(node, table)} end)}

      {:error, msg} ->
        {:noreply, assign(socket, ets_browse: %{browse | result: {:error, msg}})}
    end
  end

  def handle_event("ets_run", _params, socket), do: {:noreply, socket}

  def handle_event(
        "ets_pick",
        %{"kind" => kind, "index" => index},
        %{assigns: %{ets_browse: %{examples: {:ok, examples}} = browse}} = socket
      ) do
    case pick_example(browse, examples, kind, index) do
      {:ok, browse} -> {:noreply, assign(socket, ets_browse: browse)}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("ets_pick", _params, socket), do: {:noreply, socket}

  def handle_event("ets_view", %{"view" => view}, %{assigns: %{ets_browse: browse}} = socket)
      when browse != nil do
    view = %{"table" => :table, "pretty" => :pretty}[view] || :raw
    {:noreply, socket |> assign(ets_browse: %{browse | view: view}) |> put_output()}
  end

  def handle_event("ets_view", _params, socket), do: {:noreply, socket}

  def syntax_changed(socket), do: put_output(socket)

  @impl true
  def handle_async({:memory, kind}, {:ok, {node, value}}, %{assigns: %{node: node}} = socket) do
    socket = assign(socket, in_flight: MapSet.delete(socket.assigns.in_flight, kind))
    {:noreply, apply_read(socket, kind, value)}
  end

  # from an earlier node: the flag now belongs to the current node's read
  def handle_async({:memory, _kind}, {:ok, _stale}, socket), do: {:noreply, socket}

  def handle_async({:memory, kind}, _exit, socket),
    do: {:noreply, assign(socket, in_flight: MapSet.delete(socket.assigns.in_flight, kind))}

  def handle_async(
        {:memory_action, kind},
        {:ok, {node, result}},
        %{assigns: %{node: node}} = socket
      ),
      do: {:noreply, apply_action(socket, kind, result)}

  def handle_async({:memory_action, _kind}, {:ok, _stale}, socket),
    do: {:noreply, assign(socket, busy: nil)}

  def handle_async({:memory_action, _kind}, _exit, socket),
    do: {:noreply, assign(socket, busy: nil)}

  def handle_async(
        :ets_browse,
        {:ok, {node, table, result}},
        %{assigns: %{node: node, ets_browse: %{table: table} = browse}} = socket
      ),
      do:
        {:noreply,
         socket
         |> assign(ets_browse: %{browse | result: result |> browse_result() |> browse_rows()})
         |> put_output()}

  def handle_async(:ets_browse, _stale_or_exit, socket), do: {:noreply, socket}

  def handle_async(
        :ets_examples,
        {:ok, {node, table, result}},
        %{assigns: %{node: node, ets_browse: %{table: table} = browse}} = socket
      ),
      do: {:noreply, assign(socket, ets_browse: %{browse | examples: examples_result(result)})}

  def handle_async(:ets_examples, _stale_or_exit, socket), do: {:noreply, socket}

  def handle_async({:memory_advisor, _} = request, result, socket) do
    if request == socket.assigns.health.request do
      socket = put_health(socket, request: nil)

      case result do
        {:ok, {:ok, advice}} -> {:noreply, put_health(socket, advice: advice)}
        {:ok, {:error, message}} -> {:noreply, put_health(socket, error: message)}
        {:exit, _} -> {:noreply, put_health(socket, error: "The health check failed. Try again.")}
      end
    else
      {:noreply, socket}
    end
  end

  # Called by BeamdashWeb.Syntax when Jev is switched in Settings.
  def jev_changed(%{assigns: %{jev_enabled: true}} = socket), do: socket

  def jev_changed(socket) do
    socket =
      if r = socket.assigns.health.request, do: cancel_async(socket, r), else: socket

    assign(socket, health: %{request: nil, advice: nil, error: nil, evidence: nil})
  end

  defp start_health(socket) do
    evidence = MemoryAdvisor.evidence(socket.assigns.snap, socket.assigns.history)
    request = {:memory_advisor, make_ref()}

    socket
    |> assign(health_auto: false)
    |> assign(health: %{request: request, advice: nil, error: nil, evidence: evidence})
    |> start_async(request, fn -> MemoryAdvisor.analyze(evidence) end)
  end

  defp maybe_auto_health(
         %{assigns: %{health_auto: true, snap: snap, health: %{request: nil}}} = socket
       )
       when is_map(snap) do
    if socket.assigns.jev_enabled and Beamdash.Jev.configured?() and
         match?({:ready, _}, MemoryAdvisor.readiness(socket.assigns.history)),
       do: start_health(socket),
       else: socket
  end

  defp maybe_auto_health(socket), do: socket

  defp put_health(socket, changes),
    do: assign(socket, health: Map.merge(socket.assigns.health, Map.new(changes)))

  ## Messages

  @impl true
  # the first load runs after mount, so the page is rendered before the RPCs
  def handle_info(:start, socket) do
    {:noreply, if(socket.assigns.status == :connected, do: start(socket), else: socket)}
  end

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @refresh_ms)

    {:noreply,
     if(socket.assigns.status == :connected,
       do: socket |> request_refresh() |> maybe_auto_health(),
       else: socket
     )}
  end

  def handle_info(:ets_tick, socket) do
    Process.send_after(self(), :ets_tick, @ets_refresh_ms)
    socket = load_stored(socket)

    {:noreply,
     if(socket.assigns.status == :connected and socket.assigns.tab == :ets,
       do: request_ets(socket),
       else: socket
     )}
  end

  def handle_info({:beamdash_target, {:connected, node}}, socket),
    do:
      {:noreply,
       socket
       |> cancel_reads()
       |> assign(status: :connected, node: node, history: [], trend_history: [])
       |> start()}

  def handle_info({:beamdash_target, {:disconnected, _}}, socket),
    do:
      {:noreply,
       socket
       |> cancel_reads()
       |> assign(
         status: :disconnected,
         snap: nil,
         top: nil,
         ets: nil,
         leaks: nil,
         gc: nil,
         inspect: nil
       )}

  ## Rendering

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        parts_list: @parts,
        attrs: @attrs,
        stored_windows: @stored_windows,
        parts: if(assigns.snap, do: parts(assigns.snap.memory), else: []),
        working: working(assigns)
      )

    ~H"""
    <main id="memory-page" class="wrap">
      <BeamdashWeb.Layouts.header
        active={:memory}
        working={@working}
        syntax={@syntax}
        conn={assigns[:conn]}
        ask={assigns[:ask]}
        ask_on={BeamdashWeb.JevSection.ask_on?(assigns[:jev_enabled])}
      />

      <p :if={@status != :connected} class="help">
        Not connected: enter a node above and click Connect.
      </p>
      <p :if={@error} class="error">{@error}</p>

      <section :if={@snap} class="memory">
        <div class="mem-hero">
          <div>
            <span class="mem-total">{Format.bytes(@snap.memory.total)}</span>
            <span class="muted">in use by the VM · <code>erlang:memory()</code></span>
          </div>
          <div :if={@snap.alloc} class="muted small">
            Allocated from the OS: {Format.bytes(@snap.alloc.allocated)} · used {Format.bytes(
              @snap.alloc.used
            )} ({Float.round(@snap.alloc.usage * 100, 1)}%) <span class="muted">· recon_alloc</span>
          </div>
        </div>

        <div class="mem-bar" role="img" aria-label={bar_label(@parts)}>
          <span
            :for={{key, label, bytes, pct} <- @parts}
            :if={pct > 0}
            class={["mem-seg", "mem-#{key}"]}
            style={"flex-grow: #{bytes}"}
            title={"#{label}: #{Format.bytes(bytes)} (#{pct}%)"}
          ></span>
        </div>
        <ul class="mem-legend" aria-hidden="true">
          <li :for={{key, label, _bytes, pct} <- @parts}>
            <span class={["mem-swatch", "mem-#{key}"]}></span>{label}
            <span class="muted">{pct}%</span>
          </li>
        </ul>

        <table class="mem-table">
          <thead>
            <tr>
              <th>Kind</th>
              <th class="num">Size</th>
              <th class="num">Share</th>
              <th class="num">Last 5 min</th>
              <th>Trend</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{key, label, bytes, pct} <- @parts}>
              <td>
                <button
                  type="button"
                  class={[
                    "mem-trend-toggle",
                    !MapSet.member?(@visible_trends, key) && "muted-trend"
                  ]}
                  phx-click="toggle_trend"
                  phx-value-kind={key}
                  aria-pressed={to_string(MapSet.member?(@visible_trends, key))}
                  aria-label={"#{if MapSet.member?(@visible_trends, key), do: "Hide", else: "Show"} #{label} trend"}
                >
                  <span class={["mem-swatch", "mem-#{key}"]}></span>{label}
                </button>
                <span :if={key == :processes} class="muted small">
                  ({Format.bytes(@snap.memory.processes_used)} used)
                </span>
                <span :if={key == :atom} class="muted small">
                  ({Format.bytes(@snap.memory.atom_used)} used)
                </span>
              </td>
              <td class="num">{Format.bytes(bytes)}</td>
              <td class="num">{pct}%</td>
              <td class={["num", growth_class(growth(@history, key))]}>
                {growth_text(growth(@history, key))}
              </td>
              <td :if={key == :processes} class="memory-trend-cell" rowspan={length(@parts)}>
                <.memory_trends
                  history={@trend_history}
                  visible={@visible_trends}
                  window={@trend_window}
                />
              </td>
            </tr>
          </tbody>
        </table>

        <div class="mem-limits">
          <.meter
            label="Atoms"
            used={@snap.atom_count}
            limit={@snap.atom_limit}
            hint="atoms are never freed; at the limit the node crashes"
            tip="Atoms are names that are never garbage collected. The limit is set with +t."
            tip_href="https://www.erlang.org/doc/apps/erts/erl_cmd.html"
          />
          <.meter
            label="Processes"
            used={@snap.process_count}
            limit={@snap.process_limit}
            hint=""
            tip="Live processes against the limit set with +P. Spawning past it fails."
            tip_href="https://www.erlang.org/doc/apps/erts/erl_cmd.html"
          />
          <.meter
            :if={@snap.ets_limit}
            label="ETS tables"
            used={@snap.ets_count}
            limit={@snap.ets_limit}
            hint=""
            tip="Tables against the limit set with +e. Creating one past it fails."
            tip_href="https://www.erlang.org/doc/apps/stdlib/ets.html"
          />
          <div class="meter">
            <span class="meter-label">
              Modules loaded
              <.tip
                label="Modules loaded"
                text="Modules loaded into the node, as code:all_loaded/0 lists them."
                href="https://www.erlang.org/doc/apps/kernel/code.html#all_loaded/0"
              />
            </span>
            <span class="mono">{Format.number(@snap.module_count)}</span>
          </div>
        </div>

        <div :if={BeamdashWeb.JevSection.show?(@jev_enabled)} class="jev-card">
          <BeamdashWeb.JevSection.section
            id="jev-memory"
            event="analyze_memory"
            title={"#{Beamdash.Jev.name(@jev_backend)}: node memory health"}
            sends="Per kind of memory: size, share of the total, change and growth per second over the window; atom, process and ETS-table counts against their limits; allocated vs used."
            enabled={@jev_enabled}
            configured={Beamdash.Jev.configured?()}
            busy={@health.request != nil}
            readiness={MemoryAdvisor.readiness(@history)}
            advice={@health.advice}
            error={@health.error}
            evidence={@health.evidence}
          />
          <p :if={@health.advice && @health.advice.view} class="jev-goto">
            <button
              type="button"
              class="small-btn"
              phx-click="tab"
              phx-value-tab={@health.advice.view}
            >
              Look for a leak in {MemoryAdvisor.choices()[@health.advice.choice].label} ↓
            </button>
          </p>
        </div>

        <nav class="seg mem-pages" role="tablist" aria-label="Memory pages">
          <button
            :for={
              {page, label} <- [
                leak: "Look for a leak",
                forecast: "Forecast",
                history: "History"
              ]
            }
            type="button"
            role="tab"
            aria-selected={to_string(@page == page)}
            class={["seg-btn", @page == page && "active"]}
            phx-click="page"
            phx-value-page={page}
          >
            {label}
          </button>
        </nav>

        <div :if={@page == :forecast}>
          <.forecast forecast={@forecast} />
        </div>

        <div :if={@page == :history} class="mem-history">
          <h2 class="mem-h2">History</h2>
          <p class="guide">
            Each sample the sampler stored: total memory, atoms and ETS tables, and the change since
            the sample before it. Tables are the largest ones in each sample; the last column names
            those that grew the most since the sample before.
          </p>

          <nav class="seg" role="tablist" aria-label="History window">
            <button
              :for={{seconds, label} <- @stored_windows}
              type="button"
              role="tab"
              aria-selected={to_string(@stored_window == seconds)}
              class={["seg-btn", @stored_window == seconds && "active"]}
              phx-click="stored_window"
              phx-value-window={seconds}
            >
              {label}
            </button>
          </nav>

          <p :if={@stored && !@stored.enabled} class="muted small">
            Memory history is off. Switch on snapshot collection in Settings to keep samples.
          </p>
          <p :if={@stored && @stored.enabled && is_nil(@stored.summary)} class="muted small">
            No samples in this window yet.
          </p>

          <div :if={@stored && @stored.summary}>
            <p class="small">
              Total memory {Format.bytes(@stored.summary.from)} → {Format.bytes(@stored.summary.to)} ({growth_text(
                @stored.summary.to - @stored.summary.from
              )}), peak {Format.bytes(@stored.summary.peak)} · {Format.number(@stored.summary.samples)} samples
            </p>

            <.stored_trend points={@stored.points} from={@stored.from} window={@stored_window} />

            <table class="mem-table">
              <thead>
                <tr>
                  <th>Sampled (UTC)</th>
                  <th class="num">Memory</th>
                  <th class="num">Change</th>
                  <th class="num">Atoms</th>
                  <th class="num">ETS tables</th>
                  <th>Grew most</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @stored.rows}>
                  <td class="mono small">{clock(row.at)}</td>
                  <td class="num">{Format.bytes(row.memory)}</td>
                  <td class={["num", growth_class(row.memory_delta)]}>
                    {growth_text(row.memory_delta)}
                  </td>
                  <td class="num">
                    {Format.number(row.atoms)}
                    <span class="muted small">{count_text(row.atoms_delta)}</span>
                  </td>
                  <td class="num">
                    {Format.number(row.ets)}
                    <span class="muted small">{count_text(row.ets_delta)}</span>
                  </td>
                  <td class="small">
                    <div :for={{name, grew} <- row.growing} class="mono">
                      {name} {growth_text(grew)}
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div :if={@page == :leak}>
          <h2 class="mem-h2">Look for a leak</h2>
          <p class="muted small recon-status">{recon_text(@recon)}</p>

          <nav class="seg mem-tabs" role="tablist">
            <button
              :for={
                {tab, label, part} <-
                  [
                    processes: {"Processes", :processes},
                    binary: {"Binaries", :binary},
                    ets: {"ETS tables", :ets}
                  ]
                  |> Enum.map(fn {t, {l, p}} -> {t, l, p} end)
              }
              type="button"
              role="tab"
              aria-selected={to_string(@tab == tab)}
              class={["seg-btn", @tab == tab && "active"]}
              phx-click="tab"
              phx-value-tab={tab}
            >
              <span class={["mem-swatch", "mem-#{part}"]}></span>{label}
              <span class="muted">{Format.bytes(Map.fetch!(@snap.memory, part))}</span>
            </button>
          </nav>

          <div class={["proc-layout", "memory-layout", (@inspect || @ets_browse) && "with-panel"]}>
            <div class="proc-table">
              <div :if={@tab == :processes} class="mem-panel">
                <p class="guide">
                  Memory held by processes: usually messages piling up in a mailbox nobody reads,
                  or a process whose state keeps growing. Find the biggest ones, then look at what
                  they are doing and holding.
                </p>
                <form phx-change="attr" class="top-form">
                  <label class="muted small">
                    Top
                    <select name="n">
                      <option :for={n <- [5, 10, 20, 50]} value={n} selected={n == @top_n}>
                        {n}
                      </option>
                    </select>
                    by
                    <select name="attr">
                      <option
                        :for={{a, label} <- @attrs}
                        :if={a != :binary_memory}
                        value={a}
                        selected={a == @attr}
                      >
                        {label}
                      </option>
                    </select>
                  </label>
                  <button type="button" class="secondary small-btn" phx-click="refresh_top">Refresh</button>
                  <span :if={@top} class="muted small mono">{source_call(@top)}</span>
                </form>
                <.top_table :if={@top} top={@top} prev={@top_prev} syntax={@syntax} />
              </div>

              <div :if={@tab == :binary} class="mem-panel">
                <p class="guide">
                  Binaries over 64 bytes live in a shared heap and are freed only when no process
                  refers to them. A process that keeps a small slice of a big binary keeps all of it;
                  a process that rarely collects keeps binaries it has finished with.
                </p>
                <div id="gc-action" class="mem-action">
                  <button
                    class={["secondary", @gc && "mem-action-selected"]}
                    phx-click="gc_all"
                    phx-disable-with="Collecting…"
                  >
                    Garbage collect every process
                  </button>
                  <section :if={@gc} class="mem-result" aria-labelledby="gc-result-heading">
                    <h3 id="gc-result-heading" class="mem-h3">
                      Garbage collect every process — result
                    </h3>
                    <p class="muted small">
                      Memory before and after the collection started by this button.
                    </p>
                    <.gc_result gc={@gc} />
                  </section>
                </div>
                <div id="binary-leak-action" class="mem-action">
                  <button
                    class={["secondary", @leaks && "mem-action-selected"]}
                    phx-click="bin_leak"
                    phx-disable-with="Collecting…"
                  >
                    Find binary leaks <span class="mono small">recon:bin_leak({@top_n})</span>
                  </button>
                  <section
                    :if={@leaks}
                    class="mem-result leaks"
                    aria-labelledby="binary-leaks-heading"
                  >
                    <h3 id="binary-leaks-heading" class="mem-h3">Find binary leaks — result</h3>
                    <p class={["small", leak_class(@leaks)]}>
                      Binary memory {Format.bytes(@leaks.binary_before)} → {Format.bytes(
                        @leaks.binary_after
                      )} ({drop_text(
                        @leaks.binary_before,
                        @leaks.binary_after
                      )}) after collecting every process.
                      Processes that released the most binary references <span class="muted">({if @leaks.source == :recon, do: "recon:bin_leak", else: "built-in"})</span>:
                    </p>
                    <.top_table
                      top={%{attr: :binary_refs, source: @leaks.source, entries: @leaks.processes}}
                      prev={%{}}
                      syntax={@syntax}
                    />
                  </section>
                </div>
                <section class="mem-result" aria-labelledby="binary-current-heading">
                  <h3 id="binary-current-heading" class="mem-h3">
                    Holding the most binary memory now
                  </h3>
                  <p class="muted small">
                    Current snapshot, shown independently of the actions above.
                  </p>
                  <.top_table :if={@top} top={@top} prev={@top_prev} syntax={@syntax} />
                  <p class="guide small">
                    The fix for a slice that keeps a big binary alive: copy it out before keeping it,
                    <code>binary:copy/1</code>
                    (Elixir <code>:binary.copy/1</code>).
                  </p>
                </section>
              </div>

              <div :if={@tab == :ets} class="mem-panel">
                <p class="guide">
                  ETS tables are never garbage collected: rows stay until deleted or the owner dies.
                  A table that keeps growing is the leak. Growth is counted from when you opened this
                  page (or reset it); the list refreshes every 5 s.
                </p>
                <.ets_table
                  :if={@ets}
                  tables={@ets}
                  base={@ets_base}
                  sort={@ets_sort}
                  filter={@ets_filter}
                  syntax={@syntax}
                />
              </div>
            </div>
            <div :if={@inspect} class="proc-side memory-inspect-side">
              <.inspect_panel p={@inspect} syntax={@syntax} />
            </div>
            <div :if={@ets_browse} class="proc-side memory-inspect-side">
              <.ets_browse
                browse={@ets_browse}
                table={Enum.find(@ets || [], &(&1.id == @ets_browse.table))}
                syntax={@syntax}
              />
            </div>
          </div>
        </div>
      </section>
    </main>
    """
  end

  ## Components

  attr :history, :list, required: true
  attr :visible, :any, required: true
  attr :window, :integer, required: true

  defp memory_trends(assigns) do
    keys = Enum.filter(Keyword.keys(@parts), &MapSet.member?(assigns.visible, &1))

    latest =
      case List.last(assigns.history) do
        nil -> nil
        point -> point.at
      end

    start_at = if latest, do: latest - assigns.window * 1000, else: 0
    samples = Enum.filter(assigns.history, &(&1.at >= start_at))
    values = for point <- samples, key <- keys, do: part_bytes(point.memory, key)
    {min_value, max_value} = trend_bounds(values)
    scale = max(max_value - min_value, 1)

    series =
      for key <- keys do
        points =
          for point <- samples do
            x = (point.at - start_at) * 600 / (assigns.window * 1000)
            y = 150 - (part_bytes(point.memory, key) - min_value) / scale * 145
            {Float.round(x * 1.0, 1), Float.round(y * 1.0, 1)}
          end

        %{
          key: key,
          label: Keyword.fetch!(@parts, key),
          points: Enum.map_join(points, " ", fn {x, y} -> "#{x},#{y}" end),
          last: List.last(points)
        }
      end

    label =
      if assigns.window < 60, do: "#{assigns.window} s", else: "#{div(assigns.window, 60)} min"

    assigns =
      assign(assigns,
        series: series,
        min_value: min_value,
        max_value: max_value,
        window_label: label
      )

    ~H"""
    <div class="memory-trend-chart" id="memory-trend-chart">
      <div class="memory-trend-zoom" role="group" aria-label="Trend time window">
        <button
          type="button"
          class="secondary small-btn"
          phx-click="zoom_trend"
          phx-value-direction="in"
          disabled={@window == 30}
          aria-label="Zoom in on trend time window"
        >+</button>
        <span aria-live="polite">Last {@window_label}</span>
        <button
          type="button"
          class="secondary small-btn"
          phx-click="zoom_trend"
          phx-value-direction="out"
          disabled={@window == 600}
          aria-label="Zoom out on trend time window"
        >−</button>
      </div>
      <div class="memory-trend-axis" aria-hidden="true">
        <span>{Format.bytes(@max_value)}</span><span>{Format.bytes(@min_value)}</span>
      </div>
      <svg
        viewBox="0 0 600 155"
        preserveAspectRatio="none"
        role="img"
        aria-label={"Memory trends, last #{@window_label}; series share an automatically scaled byte range"}
      >
        <line :for={y <- [5, 77.5, 150]} x1="0" x2="600" y1={y} y2={y} class="memory-trend-grid" />
        <g :for={series <- @series} class={"memory-series-#{series.key}"}>
          <title>{series.label}</title>
          <polyline
            points={series.points}
            class="memory-trend-line"
            vector-effect="non-scaling-stroke"
          />
          <circle
            :if={series.last}
            cx={elem(series.last, 0)}
            cy={elem(series.last, 1)}
            r="3"
            class="memory-trend-dot"
            vector-effect="non-scaling-stroke"
          />
        </g>
      </svg>
      <p :if={@series == []} class="muted small">Select a memory kind to show its trend.</p>
      <p :if={@series != [] and @history == []} class="muted small">Collecting memory history…</p>
      <div class="memory-trend-time muted small"><span>−{@window_label}</span><span>Now</span></div>
    </div>
    """
  end

  attr :points, :list, required: true
  attr :from, :integer, required: true
  attr :window, :integer, required: true

  defp stored_trend(assigns) do
    {min_value, max_value} = trend_bounds(Enum.map(assigns.points, & &1.memory))
    scale = max(max_value - min_value, 1)
    span = assigns.window * 1_000

    coords =
      for point <- assigns.points do
        x = (point.at - assigns.from) * 600 / span
        y = 150 - (point.memory - min_value) / scale * 145
        {Float.round(x * 1.0, 1), Float.round(y * 1.0, 1)}
      end

    {_seconds, label} = List.keyfind(@stored_windows, assigns.window, 0)

    assigns =
      assign(assigns,
        polyline: Enum.map_join(coords, " ", fn {x, y} -> "#{x},#{y}" end),
        last: List.last(coords),
        min_value: min_value,
        max_value: max_value,
        window_label: label
      )

    ~H"""
    <div class="memory-trend-chart" id="stored-memory-trend">
      <div class="memory-trend-axis" aria-hidden="true">
        <span>{Format.bytes(@max_value)}</span><span>{Format.bytes(@min_value)}</span>
      </div>
      <svg
        viewBox="0 0 600 155"
        preserveAspectRatio="none"
        role="img"
        aria-label={"Stored total memory, last #{@window_label}"}
      >
        <line :for={y <- [5, 77.5, 150]} x1="0" x2="600" y1={y} y2={y} class="memory-trend-grid" />
        <polyline points={@polyline} class="memory-trend-line" vector-effect="non-scaling-stroke" />
        <circle
          :if={@last}
          cx={elem(@last, 0)}
          cy={elem(@last, 1)}
          r="3"
          class="memory-trend-dot"
          vector-effect="non-scaling-stroke"
        />
      </svg>
      <div class="memory-trend-time muted small"><span>−{@window_label}</span><span>Now</span></div>
    </div>
    """
  end

  defp trend_bounds([]), do: {0, 0}

  defp trend_bounds(values) do
    {lowest, highest} = Enum.min_max(values)
    padding = max((highest - lowest) * 0.05, max(highest * 0.001, 1))
    {max(0, floor(lowest - padding)), ceil(highest + padding)}
  end

  attr :forecast, :any, required: true

  # Nx: a straight line through each measure's history (Insights.Forecast)
  defp forecast(assigns) do
    ~H"""
    <section :if={@forecast} class="insights-card" aria-labelledby="forecast-heading">
      <div class="section-head">
        <h3 id="forecast-heading">Forecast</h3>
        <span :if={match?({:collecting, _, _}, @forecast)} class="muted small" role="status">
          collecting history · {elem(@forecast, 1)} of {elem(@forecast, 2)} s
        </span>
      </div>
      <p class="muted small">
        A straight line through the last few minutes of each measure (linear regression, with Nx),
        and where it leads in an hour. Highlighted “Growing” rows fit the line (R² ≥ 0.6) and grow by 5% an hour
        or more; the rest are flat or too noisy to say.
      </p>
      <table :if={match?({:ok, _}, @forecast)} class="insights-table">
        <thead>
          <tr>
            <th>Measure</th>
            <th class="num">Now</th>
            <th class="num">Per minute</th>
            <th class="num" title="How well a straight line fits (1 = perfectly)">R²</th>
            <th class="num">In an hour</th>
            <th>Limit</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={f <- elem(@forecast, 1)} class={f.growing && "forecast-growing"}>
            <td>{f.label} <span :if={f.growing} class="forecast-growing-badge">Growing</span></td>
            <td class="num mono">{forecast_value(f, f.now)}</td>
            <td class="num mono">{forecast_rate(f)}</td>
            <td class="num">{f.r2}</td>
            <td class="num mono">{if f.growing, do: forecast_value(f, f.in_1h), else: "–"}</td>
            <td class="small">
              {cond do
                f.limit_in_s -> "reached in about #{in_time(f.limit_in_s)}"
                f.limit -> "#{Format.number(f.limit)} (not approaching)"
                true -> ""
              end}
            </td>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end

  defp in_time(s) when s < 90, do: "#{s} s"
  defp in_time(s) when s < 5_400, do: "#{round(s / 60)} min"
  defp in_time(s) when s < 172_800, do: "#{round(s / 3600)} h"
  defp in_time(s), do: "#{round(s / 86_400)} days"

  defp forecast_value(%{key: key}, v) when key in [:atom_count, :process_count, :ets_count],
    do: Format.number(round(v))

  defp forecast_value(_f, v), do: Format.bytes(round(v))

  defp forecast_rate(%{per_min: per_min} = f) do
    sign = if per_min >= 0, do: "+", else: "−"
    sign <> forecast_value(f, abs(per_min))
  end

  attr :label, :string, required: true
  attr :used, :integer, required: true
  attr :limit, :integer, required: true
  attr :hint, :string, default: ""
  attr :tip, :string, required: true
  attr :tip_href, :string, required: true

  defp meter(assigns) do
    assigns = assign(assigns, pct: Float.round(assigns.used * 100 / max(assigns.limit, 1), 1))

    ~H"""
    <div class={["meter", @pct >= 80 && "warn"]} title={@hint}>
      <span class="meter-label">
        {@label}
        <.tip label={@label} text={@tip} href={@tip_href} />
      </span>
      <span class="mono">{Format.number(@used)} / {Format.number(@limit)}</span>
      <span class="meter-track"><span style={"width: #{min(@pct, 100)}%"}></span></span>
      <span class="muted small">{@pct}%{if @pct >= 80, do: " · near the limit"}</span>
    </div>
    """
  end

  attr :top, :map, required: true
  attr :prev, :map, required: true
  attr :syntax, :atom, required: true

  defp top_table(assigns) do
    # for these, a process with nothing to show is noise
    entries =
      if assigns.top.attr in [:binary_memory, :binary_refs, :message_queue_len],
        do: Enum.filter(assigns.top.entries, &(&1.value > 0)),
        else: assigns.top.entries

    assigns = assign(assigns, entries: entries)

    ~H"""
    <table class="top-table">
      <thead>
        <tr>
          <th>Process</th>
          <th class="num">{value_heading(@top.attr)}</th>
          <th class="num">Change</th>
          <th>Running</th>
          <th></th>
        </tr>
      </thead>
      <tbody>
        <tr :for={e <- @entries}>
          <td>
            <span class={e.name && "named"}>
              {if e.name, do: Format.name(e.name, @syntax), else: Format.mfa(e.initial_call, @syntax)}
            </span>
            <span class="muted small mono">{Format.pid(e.pid, @syntax)}</span>
          </td>
          <td class="num">{value_text(@top.attr, e.value)}</td>
          <td class={["num", change_class(@prev[e.pid], e.value)]}>
            {change_text(@top.attr, @prev[e.pid], e.value)}
          </td>
          <td class="mono muted small">{Format.mfa(e.current_function, @syntax)}</td>
          <td class="row-actions">
            <button
              class="secondary small-btn"
              phx-click="inspect"
              phx-value-pid={Format.pid(e.pid, :erlang)}
            >
              Inspect
            </button>
            <.link navigate={"/?pid=" <> Format.pid(e.pid, :erlang)} class="small">Details</.link>
          </td>
        </tr>
      </tbody>
    </table>
    <p :if={@entries == []} class="muted small">{empty_text(@top.attr)}</p>
    """
  end

  attr :p, :map, required: true
  attr :syntax, :atom, required: true

  defp inspect_panel(assigns) do
    ~H"""
    <aside class="proc-panel memory-inspect" id="memory-process-details">
      <div
        id="memory-panel-resizer"
        class="resizer resizer-x"
        phx-hook="Resizer"
        phx-update="ignore"
        data-var="--panel-w"
        data-axis="x"
        data-target="#memory-process-details"
        data-container=".memory-layout"
        data-keep="320"
        data-min="300"
        data-max="1400"
        role="separator"
        aria-orientation="vertical"
        aria-label="Resize the process panel"
        tabindex="0"
        title="Drag to resize · double-click to reset"
      >
      </div>
      <div class="inspect-head">
        <h3 class="mono">
          {if @p.name, do: Format.name(@p.name, @syntax), else: Format.pid(@p.pid, @syntax)}
        </h3>
        <span class="muted small">
          {Format.bytes(@p.memory)} · {Format.number(@p.message_queue_len)} queued
        </span>
        <button class="secondary small-btn" phx-click="close_inspect" aria-label="Close">×</button>
      </div>
      <h4>
        Current stack <span class="muted mono small">process_info(Pid, current_stacktrace)</span>
      </h4>
      <pre class="small">{stack_text(@p.stack, @syntax)}</pre>
      <h4>State <span class="muted mono small">sys:get_status(Pid)</span></h4>
      <%= case @p.status do %>
        <% :not_requested -> %>
          <p class="small">
            <button class="secondary small-btn" phx-click="get_status">Get state</button>
            <span class="muted">
              Sends the process a system message (OTP processes only; others time out after 2 s).
            </span>
          </p>
        <% {:ok, status} -> %>
          <pre class="small status-pre">{Format.pretty(status, @syntax)}</pre>
        <% {:error, reason} -> %>
          <p class="muted small">No state: {Format.term(reason, @syntax)}</p>
      <% end %>
    </aside>
    """
  end

  attr :gc, :map, required: true

  defp gc_result(assigns) do
    ~H"""
    <table class="gc-table">
      <thead>
        <tr>
          <th>After collecting every process</th>
          <th class="num">Before</th>
          <th class="num">After</th>
          <th class="num">Freed</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={{k, label} <- [total: "Total", processes: "Processes", binary: "Binaries"]}>
          <td>{label}</td>
          <td class="num">{Format.bytes(@gc.before[k])}</td>
          <td class="num">{Format.bytes(@gc.after[k])}</td>
          <td class={["num", @gc.before[k] - @gc.after[k] > @gc.before[k] * 0.1 && "freed"]}>
            {drop_text(@gc.before[k], @gc.after[k])}
          </td>
        </tr>
      </tbody>
    </table>
    <p class="muted small">
      If binary memory dropped a lot, processes were holding binaries they no longer used.
      “Find binary leaks” runs another collection to identify processes releasing references.
    </p>
    """
  end

  attr :tables, :list, required: true
  attr :base, :map, required: true
  attr :sort, :any, required: true
  attr :filter, :string, required: true
  attr :syntax, :atom, required: true

  defp ets_table(assigns) do
    needle = assigns.filter |> String.trim() |> String.downcase()

    rows =
      assigns.tables
      |> Enum.map(fn t ->
        base = Map.get(assigns.base, t.id, t)
        Map.merge(t, %{growth: t.memory - base.memory, rows_growth: t.size - base.size})
      end)
      |> Enum.filter(fn t ->
        needle == "" or String.contains?(String.downcase(table_name(t)), needle) or
          String.contains?(String.downcase(owner_text(t, :erlang)), needle)
      end)
      |> sort_ets(assigns.sort)

    total = Enum.reduce(assigns.tables, 0, &(&1.memory + &2))
    assigns = assign(assigns, rows: rows, total: total)

    ~H"""
    <div class="ets-tools">
      <form phx-change="ets_filter" phx-submit="ets_filter">
        <input
          type="search"
          name="q"
          value={@filter}
          placeholder="Filter by table or owner"
          phx-debounce="150"
          autocomplete="off"
        />
      </form>
      <span class="muted small">
        {length(@tables)} tables · {Format.bytes(@total)}
      </span>
      <button class="secondary small-btn" phx-click="ets_reset" title="Count growth from now">
        Reset growth
      </button>
    </div>
    <table class="ets-table">
      <thead>
        <tr>
          <th class="sortable" phx-click="ets_sort" phx-value-col="name">
            Table{arrow(@sort, :name)}
          </th>
          <th>Owner</th>
          <th>Type</th>
          <th class="num sortable" phx-click="ets_sort" phx-value-col="size">
            Rows{arrow(@sort, :size)}
          </th>
          <th class="num sortable" phx-click="ets_sort" phx-value-col="memory">
            Memory{arrow(@sort, :memory)}
          </th>
          <th class="num sortable" phx-click="ets_sort" phx-value-col="growth">
            Growth{arrow(@sort, :growth)}
          </th>
          <th></th>
        </tr>
      </thead>
      <tbody>
        <tr :for={t <- @rows} class={t.growth > 0 && "growing"}>
          <td class="mono">{table_name(t)}</td>
          <td class="small">
            <.link navigate={"/?pid=" <> Format.pid(t.owner, :erlang)}>{owner_text(t, @syntax)}</.link>
          </td>
          <td class="muted small">{t.type}, {t.protection}</td>
          <td class="num">{Format.number(t.size)}</td>
          <td class="num">{Format.bytes(t.memory)}</td>
          <td class={["num", change_class(0, t.growth)]}>
            {if t.growth == 0, do: "–", else: signed_bytes(t.growth)}
            <span :if={t.rows_growth != 0} class="muted small">
              ({if t.rows_growth > 0, do: "+"}{Format.number(t.rows_growth)} rows)
            </span>
          </td>
          <td>
            <button class="secondary small-btn" phx-click="ets_open" phx-value-id={inspect(t.id)}>
              Browse
            </button>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  attr :browse, :map, required: true
  attr :table, :map, default: nil
  attr :syntax, :atom, required: true

  defp ets_browse(assigns) do
    {rows, stop, error} =
      case assigns.browse.result do
        {:ok, %{rows: rows, stop: stop}} -> {rows, stop, nil}
        {:error, msg} -> {[], nil, msg}
        nil -> {[], nil, nil}
      end

    {example_keys, example_specs, examples_error} =
      case assigns.browse.examples do
        {:ok, examples} -> {examples.keys, examples.specs, nil}
        {:error, msg} -> {[], [], msg}
        nil -> {[], [], nil}
      end

    assigns =
      assign(assigns,
        rows: rows,
        segments: assigns.browse.output.segments,
        pairs: assigns.browse.output.pairs,
        error: error,
        summary: browse_summary(stop, length(rows)),
        limit: "Reads at most #{assigns.browse.rows} rows, for #{@browse_ms} ms per search.",
        max_rows: @browse_max_rows,
        example_keys: example_keys,
        example_specs: example_specs,
        examples_error: examples_error,
        examples_loading: is_nil(assigns.browse.examples)
      )

    ~H"""
    <aside
      class="proc-panel memory-inspect ets-browse"
      id="ets-browse-panel"
      aria-label={"Rows of #{@browse.label}"}
    >
      <div
        id="ets-browse-resizer"
        class="resizer resizer-x"
        phx-hook="Resizer"
        phx-update="ignore"
        data-var="--panel-w"
        data-axis="x"
        data-target="#ets-browse-panel"
        data-container=".memory-layout"
        data-keep="320"
        data-min="300"
        data-max="1400"
        role="separator"
        aria-orientation="vertical"
        aria-label="Resize the table panel"
        tabindex="0"
        title="Drag to resize · double-click to reset"
      >
      </div>
      <div class="inspect-head">
        <h3 class="mono">{@browse.label}</h3>
        <span class="muted small">{@limit}</span>
        <button class="secondary small-btn" phx-click="ets_close" aria-label="Close">×</button>
      </div>
      <p :if={@table} class="muted small ets-details">
        {@table.type}, {@table.protection} · owner {owner_text(@table, @syntax)} · {Format.number(
          @table.size
        )} rows · {Format.bytes(@table.memory)}
      </p>
      <p :if={@examples_loading} class="muted small">Reading the table…</p>
      <p :if={@examples_error} class="error small" role="alert">{@examples_error}</p>
      <form phx-submit="ets_run" class="ets-browse-form">
        <div class="ets-group">
          <h4>Key lookup <span class="muted mono small">:ets.lookup/2</span></h4>
          <div :if={@example_keys != []} class="ets-samples">
            <span class="muted small">Sample keys</span>
            <button
              :for={{text, i} <- Enum.with_index(@example_keys)}
              type="button"
              class="ets-sample"
              phx-click="ets_pick"
              phx-value-kind="key"
              phx-value-index={i}
              title="Use this key"
            >
              <code class="mono small">{text}</code>
            </button>
          </div>
          <div class="ets-row">
            <label class="ets-field">
              Key
              <input
                type="text"
                name="key"
                id={"ets-key-#{@browse.key_pick}"}
                value={@browse.key}
                placeholder="42 or {user, 7}"
                autocomplete="off"
                class="mono"
              />
            </label>
            <button type="submit" name="mode" value="lookup" class="secondary ets-action">
              Lookup key
            </button>
          </div>
        </div>
        <div class="ets-group">
          <h4>Search <span class="muted mono small">:ets.select/3</span></h4>
          <div :if={@example_specs != []} class="ets-samples">
            <span class="muted small">Sample match specs</span>
            <button
              :for={{{text, description}, i} <- Enum.with_index(@example_specs)}
              type="button"
              class="ets-sample"
              phx-click="ets_pick"
              phx-value-kind="spec"
              phx-value-index={i}
              title="Use this match spec"
            >
              <code class="mono small">{text}</code>
              <span class="muted small">{description}</span>
            </button>
          </div>
          <label>
            Match spec <textarea
              name="spec"
              id={"ets-spec-#{@browse.spec_pick}"}
              rows="3"
              placeholder="[{{'$1', '$2'}, [{'>', '$1', 10}], ['$_']}]"
              class="mono"
            >{@browse.spec}</textarea>
          </label>
          <div class="ets-row">
            <label class="ets-field">
              Rows
              <input
                type="number"
                name="rows"
                min="1"
                max={@max_rows}
                value={@browse.rows}
              />
            </label>
            <button type="submit" name="mode" value="select" class="secondary ets-action">
              Search
            </button>
          </div>
        </div>
      </form>
      <p :if={@error} class="error small" role="alert">{@error}</p>
      <p :if={@summary} class="muted small">{@summary}</p>
      <div :if={@rows != []}>
        <nav class="seg ets-view" role="tablist" aria-label="Output format">
          <button
            :for={{view, label} <- [raw: "Raw", pretty: "Pretty", table: "Table"]}
            type="button"
            role="tab"
            class={["seg-btn", @browse.view == view && "active"]}
            aria-selected={to_string(@browse.view == view)}
            phx-click="ets_view"
            phx-value-view={view}
          >
            {label}
          </button>
        </nav>
        <.pretty_text :if={@browse.view != :table} segments={@segments} />
        <table :if={@browse.view == :table} class="ets-kv">
          <thead>
            <tr>
              <th>Key</th>
              <th>Value</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{key, value} <- @pairs}>
              <td class="ets-rows small"><.spans segments={key} /></td>
              <td class="ets-rows small"><.spans segments={value} /></td>
            </tr>
          </tbody>
        </table>
      </div>
    </aside>
    """
  end

  attr :segments, :list, required: true

  defp pretty_text(assigns) do
    ~H"""
    <pre class="small ets-rows"><.spans segments={@segments} /></pre>
    """
  end

  attr :segments, :list, required: true

  defp spans(assigns) do
    ~H"""
    <span :for={{class, text} <- @segments} class={class}>{text}</span>
    """
  end

  ## Helpers

  # The memory parts, as {key, label, bytes, percent of total}.
  defp parts(m) do
    other = m.system - m.atom - m.binary - m.code - m.ets

    for {key, label} <- @parts do
      bytes = if key == :other, do: max(other, 0), else: Map.fetch!(m, key)
      {key, label, bytes, Float.round(bytes * 100 / max(m.total, 1), 1)}
    end
  end

  defp part_bytes(m, :other), do: max(m.system - m.atom - m.binary - m.code - m.ets, 0)
  defp part_bytes(m, key), do: Map.fetch!(m, key)

  defp bar_label(parts),
    do:
      "Memory by kind: " <>
        Enum.map_join(parts, ", ", fn {_, l, b, p} -> "#{l} #{Format.bytes(b)} (#{p}%)" end)

  defp clock(at), do: at |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%H:%M:%S")

  defp count_text(nil), do: "–"
  defp count_text(0), do: "±0"
  defp count_text(n) when n > 0, do: "+#{n}"
  defp count_text(n), do: "#{n}"

  # Change over the history window (up to 5 minutes).
  defp growth([], _key), do: nil
  defp growth([_], _key), do: nil

  defp growth(history, key),
    do: part_bytes(List.last(history).memory, key) - part_bytes(hd(history).memory, key)

  defp growth_text(nil), do: "–"
  defp growth_text(0), do: "±0"
  defp growth_text(n), do: signed_bytes(n)

  defp growth_class(n) when is_integer(n) and n > 1_048_576, do: "up"
  defp growth_class(n) when is_integer(n) and n < -1_048_576, do: "down"
  defp growth_class(_), do: nil

  defp signed_bytes(n) when n > 0, do: "+" <> Format.bytes(n)
  defp signed_bytes(n), do: "−" <> Format.bytes(-n)

  defp drop_text(before, after_) when before > 0 and after_ < before,
    do: "−#{Format.bytes(before - after_)}, #{Float.round((before - after_) * 100 / before, 1)}%"

  defp drop_text(before, after_) when after_ > before, do: "+#{Format.bytes(after_ - before)}"
  defp drop_text(_, _), do: "no change"

  defp leak_class(%{binary_before: b, binary_after: a}) when b > 0 and (b - a) / b > 0.1,
    do: "freed"

  defp leak_class(_), do: nil

  defp empty_text(:binary_memory), do: "No process holds binary memory now."
  defp empty_text(:binary_refs), do: "No process released any binaries."
  defp empty_text(:message_queue_len), do: "No process has messages waiting."
  defp empty_text(_), do: "Nothing to show."

  defp value_heading(:memory), do: "Memory"
  defp value_heading(:message_queue_len), do: "Queued"
  defp value_heading(:binary_memory), do: "Binary memory"
  defp value_heading(:reductions), do: "Reductions"
  defp value_heading(:binary_refs), do: "Released"

  defp value_text(attr, v) when attr in [:memory, :binary_memory], do: Format.bytes(v)

  defp value_text(:binary_refs, v),
    do: "#{Format.number(v)} binar#{if v == 1, do: "y", else: "ies"}"

  defp value_text(_attr, v), do: Format.number(v)

  defp change_text(_attr, nil, _v), do: ""
  defp change_text(_attr, same, same), do: "–"

  defp change_text(attr, prev, v) when attr in [:memory, :binary_memory],
    do: signed_bytes(v - prev)

  defp change_text(_attr, prev, v), do: if(v > prev, do: "+", else: "") <> Format.number(v - prev)

  defp change_class(nil, _), do: nil
  defp change_class(prev, v) when v > prev, do: "up"
  defp change_class(prev, v) when v < prev, do: "down"
  defp change_class(_, _), do: nil

  defp source_call(%{source: :recon, attr: attr, entries: e}),
    do: "recon:proc_count(#{attr}, #{length(e)})"

  defp source_call(%{source: :builtin}), do: "built-in (recon not available)"

  defp recon_text(:node), do: "Investigating with recon, the node's own copy."
  defp recon_text(:loaded), do: "Investigating with recon, loaded into the node by beamdash."

  defp recon_text(:builtin),
    do:
      "recon is not available (run mix deps.get for beamdash), so beamdash's built-in equivalents are used."

  defp recon_text(nil), do: ""

  defp stack_text(stack, syntax) when is_list(stack) do
    Enum.map_join(stack, "\n", fn
      {m, f, a, loc} ->
        where = if loc[:file], do: "  (#{loc[:file]}:#{loc[:line]})", else: ""
        Format.mfa({m, f, a}, syntax) <> where

      other ->
        Format.term(other, syntax)
    end)
  end

  defp stack_text(_, _), do: ""

  defp table_name(%{named: true, name: name}), do: Atom.to_string(name)
  defp table_name(%{name: name, id: id}), do: "#{name} #{inspect(id)}"

  defp owner_text(%{owner_name: name, owner: pid}, syntax) when is_atom(name) and name != nil,
    do: "#{Format.name(name, syntax)} #{Format.pid(pid, syntax)}"

  defp owner_text(%{owner: pid}, syntax), do: Format.pid(pid, syntax)

  defp sort_ets(rows, {:name, dir}), do: Enum.sort_by(rows, &String.downcase(table_name(&1)), dir)
  defp sort_ets(rows, {col, dir}), do: Enum.sort_by(rows, &Map.fetch!(&1, col), dir)

  defp arrow({col, :asc}, col), do: " ▲"
  defp arrow({col, :desc}, col), do: " ▼"
  defp arrow(_sort, _col), do: ""
end
