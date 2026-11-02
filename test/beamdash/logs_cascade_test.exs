defmodule Beamdash.LogsCascadeTest do
  use ExUnit.Case, async: true

  alias Beamdash.Logs.Cascade

  @t0 ~U[2026-11-01 10:00:00Z]

  # What OTP 28's logger_formatter makes of a crashing gen_server `w` under
  # supervisor `s` (intensity 2), as beamdash's logger handler sends it
  # (multi-line), stack traces shortened.
  defp erl_crash(pid) do
    [
      {:error, pid,
       """
       ** Generic server w terminating
       ** Last message in was {'$gen_cast',boom}
       ** When Server state == nil
       ** Reason for termination ==
       ** {boom,[{w,handle_cast,2,[{file,"w.erl"},{line,6}]},
                 {proc_lib,init_p_do_apply,3,[{file,"proc_lib.erl"},{line,333}]}]}
       """},
      {:error, pid,
       """
         crasher:
           initial call: w:init/1
           pid: #{pid}
           registered_name: w
           exception error: boom
             in function  w:handle_cast/2 (w.erl:6)
           ancestors: [s,<0.10.0>]
           message_queue_len: 0
           links: [<0.83.0>]
         neighbours:
       """},
      {:error, "<0.83.0>",
       """
           supervisor: {local,s}
           errorContext: child_terminated
           reason: {boom,[{w,handle_cast,2,[{file,"w.erl"},{line,6}]},
                          {proc_lib,init_p_do_apply,3,
                                    [{file,"proc_lib.erl"},{line,333}]}]}
           offender: [{pid,#{pid}},
                      {id,w},
                      {mfargs,{w,start_link,[]}},
                      {restart_type,permanent},
                      {child_type,worker}]
       """}
    ]
  end

  defp erl_gave_up do
    {:error, "<0.83.0>",
     """
         supervisor: {local,s}
         errorContext: shutdown
         reason: reached_max_restart_intensity
         offender: [{pid,<0.87.0>},
                    {id,w},
                    {mfargs,{w,start_link,[]}},
                    {restart_type,permanent},
                    {child_type,worker}]
     """}
  end

  # [{level, pid, message}] oldest first, 30 ms apart, to entries newest first
  defp entries(lines, start_ms \\ 0) do
    lines
    |> Enum.with_index(1)
    |> Enum.map(fn {{level, pid, message}, i} ->
      %{
        id: i,
        at: DateTime.add(@t0, start_ms + i * 30, :millisecond),
        level: level,
        pid: pid,
        where: nil,
        message: message,
        meta: [],
        raw: message
      }
    end)
    |> Enum.reverse()
  end

  defp chain(incident),
    do: Enum.map(incident.rows, &{&1.depth, &1.node.name, &1.node.crashes})

  describe "event/1" do
    test "Erlang's crash, gen_server and supervisor reports" do
      [gen, crash, sup] = entries(erl_crash("<0.85.0>")) |> Enum.reverse()

      assert %{kind: :crash, name: "w", pid: "<0.85.0>", reason: "boom"} = Cascade.event(gen)

      assert %{kind: :crash, name: "w", pid: "<0.85.0>", reason: "boom", ancestors: ["s"]} =
               Cascade.event(crash)

      assert %{
               kind: :child_terminated,
               supervisor: "s",
               name: "w",
               child_pid: "<0.85.0>",
               reason: "boom"
             } = Cascade.event(sup)

      [gave_up] = entries([erl_gave_up()])

      assert %{kind: :shutdown, supervisor: "s", reason: "reached_max_restart_intensity"} =
               Cascade.event(gave_up)
    end

    test "Erlang's single-line formats" do
      for {message, expected} <- [
            {"Supervisor: {local,s}. Context: child_terminated. Reason: {boom,[{w,handle_cast,2,[]}]}. Offender: id=w,pid=<0.85.0>.",
             %{kind: :child_terminated, supervisor: "s", name: "w", child_pid: "<0.85.0>"}},
            {"Supervisor: {local,s}. Context: shutdown. Reason: reached_max_restart_intensity. Offender: id=w,pid=<0.87.0>.",
             %{kind: :shutdown, supervisor: "s", reason: "reached_max_restart_intensity"}},
            {"crasher: initial call: w:init/1, pid: <0.85.0>, registered_name: w, error: {boom,[{w,handle_cast,2,[]}]}, ancestors: [s,<0.10.0>], message_queue_len: 0",
             %{kind: :crash, name: "w", pid: "<0.85.0>", reason: "boom", ancestors: ["s"]}},
            {"Generic server w terminating. Reason: {boom,[{w,handle_cast,2,[]}]}. Last message: {'$gen_cast',boom}. State: nil.",
             %{kind: :crash, name: "w", reason: "boom"}},
            {"Application: demo. Exited: shutdown. Type: temporary.",
             %{kind: :app_exit, application: "demo", reason: "shutdown"}}
          ] do
        [entry] = entries([{:error, nil, message}])
        event = Cascade.event(entry)
        assert Map.take(event, Map.keys(expected)) == expected, message
      end
    end

    test "Elixir's terminating, supervisor and application lines" do
      for {message, expected} <- [
            {"GenServer MyApp.Worker terminating\n** (RuntimeError) boom\n    lib/w.ex:8: MyApp.Worker.handle_cast/2\nLast message: {:\"$gen_cast\", :boom}",
             %{kind: :crash, name: "MyApp.Worker", reason: "(RuntimeError) boom", pid: "<0.90.0>"}},
            {"Process MyApp.Worker (#PID<0.91.0>) terminating\n** (RuntimeError) boom\nInitial Call: MyApp.Worker.init/1\nAncestors: [MyApp.Sup, #PID<0.80.0>]",
             %{kind: :crash, name: "MyApp.Worker", pid: "<0.91.0>", ancestors: ["MyApp.Sup"]}},
            {"Task #PID<0.92.0> started from MyApp.Server terminating\n** (ArithmeticError) bad argument",
             %{kind: :crash, name: "<0.92.0>", pid: "<0.92.0>"}},
            {"Child MyApp.Worker of Supervisor MyApp.Sup terminated\n** (exit) killed\nPid: #PID<0.93.0>\nStart Call: MyApp.Worker.start_link([])",
             %{
               kind: :child_terminated,
               supervisor: "MyApp.Sup",
               name: "MyApp.Worker",
               child_pid: "<0.93.0>",
               reason: "killed"
             }},
            {"Child MyApp.Worker of Supervisor MyApp.Sup caused shutdown\n** (exit) :reached_max_restart_intensity",
             %{kind: :shutdown, supervisor: "MyApp.Sup", reason: ":reached_max_restart_intensity"}},
            {"Child :worker of Supervisor MyApp.Sup failed to start\n** (exit) :bad",
             %{kind: :start_error, supervisor: "MyApp.Sup", name: "worker"}},
            {"Application my_app exited: shutdown",
             %{kind: :app_exit, application: "my_app", reason: "shutdown"}}
          ] do
        [entry] = entries([{:error, "<0.90.0>", message}])
        event = Cascade.event(entry)
        assert Map.take(event, Map.keys(expected)) == expected, message
      end
    end

    test "other lines are no crash" do
      [entry] = entries([{:info, nil, "GET /users 200 in 3ms"}])
      assert Cascade.event(entry) == nil
      assert Cascade.event(%{message: nil}) == nil
    end
  end

  describe "build/2" do
    test "an Erlang restart loop: the three reports of each crash are one crash" do
      lines =
        erl_crash("<0.85.0>") ++ erl_crash("<0.86.0>") ++ erl_crash("<0.87.0>") ++ [erl_gave_up()]

      assert [incident] = Cascade.build(entries(lines))
      assert %{crashes: 3, processes: 1, gave_up: ["s"], app_exits: []} = incident
      assert chain(incident) == [{0, "s", 0}, {1, "w", 3}]

      [%{node: s}, %{node: w}] = incident.rows
      assert s.supervisor?
      assert s.gave_up == "reached_max_restart_intensity"
      assert w.pids == ["<0.85.0>", "<0.86.0>", "<0.87.0>"]
      assert w.reasons == [{"boom", 3}]
      assert length(w.entry_ids) == 9
      assert length(incident.entry_ids) == 10
    end

    test "crashes more than 10 s apart are separate incidents, newest first" do
      lines = entries(erl_crash("<0.85.0>")) ++ entries(erl_crash("<0.86.0>"), 60_000)
      # (ids must be unique)
      lines = lines |> Enum.with_index() |> Enum.map(fn {e, i} -> %{e | id: 100 - i} end)
      lines = Enum.sort_by(lines, & &1.at, {:desc, DateTime})

      assert [newer, older] = Cascade.build(lines)
      assert DateTime.compare(newer.from, older.to) == :gt
      assert newer.crashes == 1 and older.crashes == 1
    end

    test "Elixir: terminating lines by pid, the supervisors from the node" do
      crash = fn pid ->
        {:error, pid, "GenServer MyApp.Worker terminating\n** (RuntimeError) boom\nState: nil"}
      end

      entries = entries([crash.("<0.90.0>"), crash.("<0.91.0>")])
      assert Cascade.unknown_names(entries, %{}) == ["MyApp.Worker"]
      assert Cascade.unknown_names(entries, %{"MyApp.Worker" => []}) == []

      [alone] = Cascade.build(entries)
      assert chain(alone) == [{0, "MyApp.Worker", 2}]

      known = %{"MyApp.Worker" => ["MyApp.Sup", "MyApp.Top"]}
      [incident] = Cascade.build(entries, ancestors: known)

      assert chain(incident) ==
               [{0, "MyApp.Top", 0}, {1, "MyApp.Sup", 0}, {2, "MyApp.Worker", 2}]

      assert incident |> Map.get(:rows) |> hd() |> get_in([:node, :supervisor?])
    end

    test "names are made comparable" do
      assert Cascade.name("{local,demo_sup}") == "demo_sup"
      assert Cascade.name("#PID<0.1.0>") == "<0.1.0>"
      assert Cascade.name(":worker") == "worker"
      assert Cascade.name("Elixir.Foo") == "Foo"
      assert Cascade.name(" MyApp.Sup ") == "MyApp.Sup"
    end

    test "no crashes" do
      assert Cascade.build(entries([{:info, nil, "hello"}])) == []
      assert Cascade.build([]) == []
    end
  end
end
