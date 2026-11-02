defmodule Beamdash.Logs.Cascade do
  @moduledoc """
  The Logs tab's Crashes view: crashes in the log lines, grouped into
  incidents, each drawn as the supervision chain it ran through: which
  processes crashed and how often, under which supervisor, which
  supervisor gave up (reached its restart intensity) and which
  application exited.

  The steps are read from the lines OTP and Elixir log
  (`event/1`), in either the multi-line or the single-line format:

    * a crash: Erlang's crash report (`crasher:`, with its `ancestors`),
      `Generic server X terminating`, `State machine X terminating`, or
      Elixir's `GenServer X terminating`, `Process X terminating`, `Task
      X ... terminating`;
    * a supervisor report: Erlang's `supervisor: ... errorContext: ...` /
      `Supervisor: X. Context: Y.`, or Elixir's `Child X of Supervisor Y
      terminated` (also `caused shutdown`, `failed to start`, `shut down
      abnormally`);
    * an application exit: `application: X exited: Y` / `Application X
      exited: Y`.

  The reports of one crash (Erlang logs three) are joined by the crashed
  pid, or by name within a second when a line has no pid. Crashes less
  than #{10} s apart are one incident.

  Elixir's Logger drops supervisor and crash reports unless
  `handle_sasl_reports` is set, so a crash there is often only
  `GenServer X terminating`. A process's supervisors then come from
  `ancestors` (name to its supervisors, nearest first: the node's
  `$ancestors` for the processes registered now, see
  `Beamdash.Target.process_ancestors/2`).
  """

  @gap_us 10_000_000
  @same_crash_us 1_000_000
  @max_reason 160

  # Functions, not attributes: compiled regexes can't be escaped into code
  # on OTP 28 with Elixir < 1.19.
  defp re(:pid), do: ~r/<\d+\.\d+\.\d+>/

  defp re(:ex_terminating),
    do:
      ~r/\A(?:GenServer|:gen_statem|GenStateMachine|:gen_event|GenEvent) (.+?) terminating\n\*\* (.+)/

  defp re(:ex_process),
    do:
      ~r/\A(?:Process|Task) (#PID<[\d.]+>|\S+)(?: \((#PID<[\d.]+>)\))?(?: started from \S+)? terminating(?:\n\*\* (.+))?/

  defp re(:ex_child),
    do:
      ~r/\AChild (.+?) of Supervisor (.+?) (terminated|caused shutdown|failed to start|shut down abnormally)/

  defp re(:ex_exit), do: ~r/^\*\* \(exit\) (.+)$/m
  defp re(:ex_pid), do: ~r/^Pid: (#PID<[\d.]+>)/m
  defp re(:ex_ancestors), do: ~r/^Ancestors: \[(.*)\]$/m
  defp re(:ex_app), do: ~r/\AApplication (\S+) exited: (.+)/
  defp re(:erl_gen), do: ~r/\A\s*\*\* (?:Generic server|State machine) (\S+) terminating/
  defp re(:erl_gen_reason), do: ~r/\*\* Reason for termination ==\s*\n\*\* (.+)/

  defp re(:erl_gen1),
    do: ~r/\A(?:Generic server|State machine) (\S+) terminating\. Reason: (.*?)\. (?:Last|State)/s

  defp re(:erl_sup),
    do: ~r/\A\s*supervisor: (.+)\n\s*errorContext: (\w+)\n\s*reason: (.*?)\n\s*offender: (.*)\z/s

  defp re(:erl_sup1),
    do: ~r/\ASupervisor: (.+?)\. Context: (\w+)\. Reason: (.*?)\. Offender: (.*)\z/s

  defp re(:erl_crasher), do: ~r/\A\s*crasher:/
  defp re(:erl_crash_pid), do: ~r/\bpid: (<[\d.]+>)/
  defp re(:erl_crash_name), do: ~r/\bregistered_name: ([^,\s]+)/

  defp re(:erl_crash_reason),
    do: ~r/(?:^\s*exception \w+: |, (?:error|exit|throw): )(.+?)(?:, ancestors:|$)/m

  defp re(:erl_crash_ancestors), do: ~r/\bancestors: \[([^\]]*)\]/

  defp re(:erl_app),
    do: ~r/\A\s*[Aa]pplication: (\S+?)\.?\s+[Ee]xited: (.+?)(?:\.?\s+[Tt]ype: |\z)/s

  defp re(:offender_id), do: ~r/(?:\{id,|\bid=)([^,}\s]+)/
  defp re(:offender_pid), do: ~r/(?:\{pid,|\bpid=)(<[\d.]+>)/
  defp re(:term_reason), do: ~r/\A\{([^{},\[]+),\s*\[\{/

  @doc """
  What a log line says about a crash, or nil: `%{kind, name, pid,
  supervisor, reason, ancestors, application}` (only the keys the line
  gives), `kind` one of `:crash`, `:child_terminated`, `:shutdown` (a
  supervisor gave up or shut down abnormally), `:start_error`,
  `:app_exit`.
  """
  def event(%{message: message} = entry) when is_binary(message) do
    case parse(message) do
      nil -> nil
      event -> Map.put_new(event, :pid, if(event.kind == :crash, do: pid_text(entry[:pid])))
    end
  end

  def event(_entry), do: nil

  defp parse(m) do
    cond do
      r = Regex.run(re(:ex_terminating), m) ->
        [_, name, reason] = r
        crash(name, nil, reason, ancestors_line(m))

      r = Regex.run(re(:ex_process), m) ->
        name = Enum.at(r, 1)
        pid = if String.starts_with?(name, "#PID"), do: name, else: blank(Enum.at(r, 2))
        crash(name, pid, blank(Enum.at(r, 3)), ancestors_line(m))

      r = Regex.run(re(:ex_child), m) ->
        [_, child, sup, what] = r
        reason = with [_, reason] <- Regex.run(re(:ex_exit), m), do: reason

        supervisor_event(ex_context(what), sup, child, capture(re(:ex_pid), m), reason)

      r = Regex.run(re(:ex_app), m) ->
        [_, app, reason] = r
        %{kind: :app_exit, application: name(app), reason: short(reason)}

      r = Regex.run(re(:erl_sup), m) || Regex.run(re(:erl_sup1), m) ->
        [_, sup, context, reason, offender] = r

        supervisor_event(
          erl_context(context),
          sup,
          capture(re(:offender_id), offender),
          capture(re(:offender_pid), offender),
          reason
        )

      Regex.match?(re(:erl_crasher), m) ->
        registered = capture(re(:erl_crash_name), m)

        crash(
          if(registered != "[]", do: registered),
          capture(re(:erl_crash_pid), m),
          capture(re(:erl_crash_reason), m),
          case Regex.run(re(:erl_crash_ancestors), m) do
            [_, list] -> names(list)
            nil -> []
          end
        )

      r = Regex.run(re(:erl_gen1), m) ->
        [_, name, reason] = r
        crash(name, nil, reason, [])

      r = Regex.run(re(:erl_gen), m) ->
        crash(Enum.at(r, 1), nil, capture(re(:erl_gen_reason), m), [])

      r = Regex.run(re(:erl_app), m) ->
        [_, app, reason] = r
        %{kind: :app_exit, application: name(app), reason: short(reason)}

      true ->
        nil
    end
  end

  defp crash(name, pid, reason, ancestors) do
    %{
      kind: :crash,
      name: name && name(name),
      pid: pid && name(pid),
      reason: short(reason),
      ancestors: ancestors
    }
    |> Map.reject(fn {_k, v} -> v == nil end)
  end

  defp supervisor_event(nil, _sup, _child, _pid, _reason), do: nil

  defp supervisor_event(kind, sup, child, pid, reason) do
    %{
      kind: kind,
      supervisor: name(sup),
      name: child && name(child),
      child_pid: pid && name(pid),
      reason: short(reason)
    }
    |> Map.reject(fn {_k, v} -> v == nil end)
  end

  defp ex_context("terminated"), do: :child_terminated
  defp ex_context("caused shutdown"), do: :shutdown
  defp ex_context("shut down abnormally"), do: :shutdown
  defp ex_context("failed to start"), do: :start_error

  defp erl_context("child_terminated"), do: :child_terminated
  defp erl_context("shutdown"), do: :shutdown
  defp erl_context("shutdown_error"), do: :shutdown
  defp erl_context("start_error"), do: :start_error
  defp erl_context(_), do: nil

  defp ancestors_line(m) do
    case Regex.run(re(:ex_ancestors), m) do
      [_, list] -> names(list)
      nil -> []
    end
  end

  defp blank(""), do: nil
  defp blank(value), do: value

  defp capture(regex, text) do
    case Regex.run(regex, text) do
      [_, value | _] -> value
      _ -> nil
    end
  end

  # the named ancestors (a pid names no process anyone knows)
  defp names(list) do
    list
    |> String.split(",")
    |> Enum.map(&name/1)
    |> Enum.reject(&(&1 == "" or Regex.match?(re(:pid), &1)))
  end

  @doc """
  A process or supervisor name as one text: `{local,s}` → `s`, `#PID<0.1.0>`
  → `<0.1.0>`, `:worker` → `worker`, `Elixir.Foo` → `Foo`.
  """
  def name(text) do
    text = String.trim(text)

    cond do
      r = Regex.run(~r/\A\{(?:local|global),\s*(.+)\}\z/, text) -> name(Enum.at(r, 1))
      r = Regex.run(~r/\A\{:(?:local|global),\s*(.+)\}\z/, text) -> name(Enum.at(r, 1))
      r = Regex.run(~r/\A#PID(<[\d.]+>)\z/, text) -> Enum.at(r, 1)
      String.starts_with?(text, "Elixir.") -> String.replace_prefix(text, "Elixir.", "")
      Regex.match?(~r/\A:[a-z_][\w@]*\z/, text) -> String.trim_leading(text, ":")
      true -> text
    end
  end

  # one line of the reason: an Erlang `{reason,[{m,f,a,..}|..]}` keeps
  # the reason, and long terms are cut
  defp short(nil), do: nil

  defp short(reason) do
    line = reason |> String.split("\n", parts: 2) |> hd() |> String.trim()

    line =
      case Regex.run(re(:term_reason), line) do
        [_, reason] -> String.trim(reason)
        nil -> line
      end

    if String.length(line) > @max_reason,
      do: String.slice(line, 0, @max_reason) <> "…",
      else: line
  end

  defp pid_text(pid) when is_binary(pid), do: if(Regex.match?(re(:pid), pid), do: name(pid))
  defp pid_text(_), do: nil

  @doc """
  The incidents in `entries` (newest first), newest first: `%{id, from,
  to, crashes, processes, gave_up, app_exits, rows, entry_ids}`. `rows`
  are the chain's nodes depth first, `%{node, depth}`; a node is `%{name,
  supervisor?, crashes, pids, reasons, gave_up, start_errors, first_at,
  last_at, entry_ids}`, `reasons` `[{reason, count}]` most common first.

  Options: `ancestors` (name to its supervisors, nearest first).
  """
  def build(entries, opts \\ []) do
    known = Keyword.get(opts, :ancestors, %{})

    events =
      for %{at: %DateTime{} = at} = entry <- Enum.reverse(entries),
          event = event(entry),
          do: Map.merge(event, %{at: DateTime.to_unix(at, :microsecond), entry_id: entry.id})

    {crash_events, others} =
      Enum.split_with(events, &(&1.kind in [:crash, :child_terminated]))

    occurrences = occurrences(crash_events)
    parents = parents(occurrences, others, known)

    items =
      Enum.map(occurrences, &{:crash, &1}) ++
        for e <- others, e.kind != :child_terminated, do: {e.kind, e}

    items
    |> Enum.sort_by(fn {_, item} -> item.at end)
    |> chunk()
    |> Enum.map(&incident(&1, parents))
    |> Enum.reverse()
  end

  # one crash per pid (Erlang logs a crash report, a gen_server report and
  # the supervisor's), or per name within a second without a pid
  defp occurrences(events) do
    Enum.reduce(events, [], fn event, acc ->
      pid = event[:pid] || event[:child_pid]

      case Enum.find_index(acc, &same_crash?(&1, event, pid)) do
        nil -> [occurrence(event, pid) | acc]
        i -> List.update_at(acc, i, &join(&1, event, pid))
      end
    end)
    |> Enum.reverse()
  end

  defp same_crash?(occ, event, pid) do
    cond do
      pid != nil and occ.pid != nil -> pid == occ.pid
      true -> abs(occ.at - event.at) <= @same_crash_us and event[:name] in occ.names
    end
  end

  defp occurrence(event, pid) do
    join(
      %{
        pid: nil,
        names: [],
        name: nil,
        at: event.at,
        crash_reason: nil,
        sup_reason: nil,
        supervisor: nil,
        ancestors: [],
        entry_ids: []
      },
      event,
      pid
    )
  end

  # a crash report's or terminate line's name and reason win over the
  # supervisor's child id and reason
  defp join(occ, event, pid) do
    crash? = event.kind == :crash

    %{
      occ
      | pid: occ.pid || pid,
        names: Enum.uniq(occ.names ++ List.wrap(event[:name])),
        name: occ.name || if(crash?, do: event[:name]),
        at: min(occ.at, event.at),
        crash_reason: occ.crash_reason || if(crash?, do: event[:reason]),
        sup_reason: occ.sup_reason || if(not crash?, do: event[:reason]),
        supervisor: occ.supervisor || event[:supervisor],
        ancestors: if(occ.ancestors == [], do: event[:ancestors] || [], else: occ.ancestors),
        entry_ids: [event.entry_id | occ.entry_ids]
    }
  end

  defp reason(occ), do: occ.crash_reason || occ.sup_reason

  defp key(occ), do: occ.name || List.first(occ.names) || occ.pid || "unknown process"

  # name → its supervisor: from supervisor reports, then crash reports'
  # ancestors, then the node's
  defp parents(occurrences, others, known) do
    from_reports =
      for occ <- occurrences, occ.supervisor != nil, into: %{}, do: {key(occ), occ.supervisor}

    from_reports =
      Enum.reduce(others, from_reports, fn
        %{kind: kind, name: child, supervisor: sup}, acc when kind in [:start_error, :shutdown] ->
          if child != sup, do: Map.put_new(acc, child, sup), else: acc

        _, acc ->
          acc
      end)

    chains =
      for occ <- occurrences do
        {key(occ), if(occ.ancestors != [], do: occ.ancestors, else: Map.get(known, key(occ), []))}
      end

    # every supervisor named so far: its own chain from the node
    chains = chains ++ for {name, chain} <- known, do: {name, chain}

    Enum.reduce(chains, from_reports, fn {name, chain}, acc ->
      [name | chain]
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.reduce(acc, fn [child, parent], acc ->
        if child != parent, do: Map.put_new(acc, child, parent), else: acc
      end)
    end)
  end

  defp chunk([]), do: []

  defp chunk([first | rest]) do
    {chunks, current, _} =
      Enum.reduce(rest, {[], [first], elem(first, 1).at}, fn {_, item} = x,
                                                             {chunks, current, last} ->
        if item.at - last > @gap_us,
          do: {[Enum.reverse(current) | chunks], [x], item.at},
          else: {chunks, [x | current], item.at}
      end)

    Enum.reverse([Enum.reverse(current) | chunks])
  end

  defp incident(items, parents) do
    nodes =
      Enum.reduce(items, %{}, fn
        {:crash, occ}, acc ->
          update(acc, key(occ), occ.at, occ.entry_ids, fn n ->
            %{
              n
              | crashes: n.crashes + 1,
                pids: Enum.uniq(n.pids ++ List.wrap(occ.pid)),
                reasons: [reason(occ) || "?" | n.reasons]
            }
          end)

        {:shutdown, e}, acc ->
          update(
            acc,
            e.supervisor,
            e.at,
            [e.entry_id],
            &%{&1 | gave_up: &1.gave_up || e[:reason]}
          )

        {:start_error, e}, acc ->
          update(
            acc,
            e[:name] || "unknown child",
            e.at,
            [e.entry_id],
            &%{&1 | start_errors: &1.start_errors + 1}
          )

        {:app_exit, _e}, acc ->
          acc
      end)

    # the supervisors above them, as far as names go
    nodes = Enum.reduce(Map.keys(nodes), nodes, &add_ancestors(&2, &1, parents, 0))
    names = Map.keys(nodes)

    children =
      Enum.group_by(names, &(parents[&1] in names and parents[&1]), & &1)

    roots = Enum.reject(names, &(parents[&1] in names))
    supervisors = MapSet.new(for n <- names, p = parents[n], p in names, do: p)

    nodes =
      Map.new(nodes, fn {name, n} ->
        {name, %{n | supervisor?: MapSet.member?(supervisors, name) or n.gave_up != nil}}
      end)

    rows = rows(Enum.sort_by(roots, &sort_key(nodes[&1])), nodes, children, 0)
    times = for {_, item} <- items, do: item.at
    crashed = for {:crash, occ} <- items, do: occ

    %{
      id: "c#{List.first(times)}",
      from: datetime(Enum.min(times)),
      to: datetime(Enum.max(times)),
      crashes: length(crashed),
      processes: crashed |> Enum.map(&key/1) |> Enum.uniq() |> length(),
      gave_up: for({:shutdown, e} <- items, do: e.supervisor) |> Enum.uniq(),
      app_exits: for({:app_exit, e} <- items, do: {e.application, e.reason}) |> Enum.uniq(),
      rows: rows,
      entry_ids:
        items
        |> Enum.flat_map(fn {_, i} -> Map.get(i, :entry_ids) || [i.entry_id] end)
        |> Enum.uniq()
    }
  end

  defp update(nodes, name, at, entry_ids, fun) do
    node =
      Map.get(nodes, name, %{
        name: name,
        supervisor?: false,
        crashes: 0,
        pids: [],
        reasons: [],
        gave_up: nil,
        start_errors: 0,
        first: at,
        last: at,
        entry_ids: []
      })

    node = %{
      node
      | first: min(node.first, at),
        last: max(node.last, at),
        entry_ids: entry_ids ++ node.entry_ids
    }

    Map.put(nodes, name, fun.(node))
  end

  # (depth-limited: a loop in made-up names never hangs)
  defp add_ancestors(nodes, name, parents, depth) do
    case parents[name] do
      nil ->
        nodes

      parent when depth < 20 ->
        nodes =
          Map.put_new(nodes, parent, %{
            name: parent,
            supervisor?: true,
            crashes: 0,
            pids: [],
            reasons: [],
            gave_up: nil,
            start_errors: 0,
            first: nil,
            last: nil,
            entry_ids: []
          })

        add_ancestors(nodes, parent, parents, depth + 1)

      _ ->
        nodes
    end
  end

  defp rows(names, nodes, children, depth) when depth < 20 do
    Enum.flat_map(names, fn name ->
      kids = children |> Map.get(name, []) |> Enum.sort_by(&sort_key(nodes[&1]))
      [%{node: present(nodes[name]), depth: depth} | rows(kids, nodes, children, depth + 1)]
    end)
  end

  defp rows(_names, _nodes, _children, _depth), do: []

  defp sort_key(n), do: {-(n.crashes + n.start_errors + if(n.gave_up, do: 1, else: 0)), n.name}

  defp present(n) do
    reasons =
      n.reasons
      |> Enum.frequencies()
      |> Enum.sort_by(fn {reason, count} -> {-count, reason} end)

    n
    |> Map.drop([:first, :last])
    |> Map.merge(%{
      reasons: reasons,
      first_at: n.first && datetime(n.first),
      last_at: n.last && datetime(n.last),
      entry_ids: Enum.uniq(n.entry_ids)
    })
  end

  defp datetime(us), do: DateTime.from_unix!(us, :microsecond)

  @doc "The names whose supervisors no line gave and `known` lacks, to ask the node for."
  def unknown_names(entries, known) do
    for %{kind: :crash} = event <- Enum.map(entries, &event/1),
        event[:ancestors] in [nil, []],
        name = event[:name],
        name != nil and not Map.has_key?(known, name) and not String.starts_with?(name, "<"),
        uniq: true,
        do: name
  end
end
