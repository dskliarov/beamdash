defmodule Beamdash.LogsTest do
  use ExUnit.Case, async: false

  alias Beamdash.{Logs, Target}
  alias Beamdash.Test.Fixture

  @moduletag :capture_log

  @script "printf '2026-10-23T12:00:00Z [info] one\\n2026-10-23T12:00:01Z [error] two\\n2026-10-23T12:00:01Z     at line 1\\n'"

  @kubectl {:kubectl, %{kubeconfig: nil, namespace: "ns", pod: "p", container: nil}}

  setup do
    {peer, node} = Fixture.start_peer()
    on_exit(fn -> Fixture.stop_peer(peer) end)

    id = System.unique_integer([:positive])
    target = start_supervised!({Target, name: :"target_#{id}"}, id: :target)

    %{peer: peer, node: node, target: target, id: id}
  end

  defp connect(ctx) do
    {:ok, _} = Target.connect(Atom.to_string(ctx.node), Fixture.cookie(), ctx.target)
    :ok
  end

  defp start_logs(ctx, opts \\ []) do
    start_supervised!({Logs, [name: :"logs_#{ctx.id}", target: ctx.target] ++ opts}, id: :logs)
  end

  defp sh(script), do: fn _args -> {System.find_executable("sh"), ["-c", script]} end

  # the `kubectl logs -f` stream (the fallback when no handler can be added)
  defp kubectl_logs(ctx, script) do
    logs =
      start_logs(ctx,
        source_fun: fn _ -> @kubectl end,
        logs_cmd: sh(script),
        kubectl_logger: false
      )

    :ok = Logs.subscribe(logs)
    :ok = connect(ctx)
    logs
  end

  # Polls `fun` until it returns a truthy value, or fails after `timeout` ms.
  defp eventually(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_until(fun, deadline)
  end

  defp wait_until(fun, deadline) do
    if result = fun.() do
      result
    else
      if System.monotonic_time(:millisecond) > deadline do
        flunk("condition not met in time")
      else
        Process.sleep(20)
        wait_until(fun, deadline)
      end
    end
  end

  # Every {:entries, batch} subscriber message currently in the mailbox.
  defp drain_batches(acc) do
    receive do
      {:beamdash_logs, {:entries, batch}} -> drain_batches([batch | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "direct source" do
    test "log events on the node arrive as entries", ctx do
      logs = start_logs(ctx)
      :ok = Logs.subscribe(logs)
      :ok = connect(ctx)
      eventually(fn -> Logs.info(logs).status == :streaming end)

      :ok = Fixture.log(ctx.node, :error, "boom ~p", [1])

      assert_receive {:beamdash_logs, {:entries, [e]}}, 3_000
      assert e.level == :error
      assert e.message == "boom 1"
      assert e.raw =~ "[error]"
      assert is_integer(e.id)
      assert e.where == nil or is_binary(e.where)

      assert e in Logs.entries(logs)
      assert %{source: :direct, status: :streaming} = Logs.info(logs)
    end

    test "where is the mfa in Erlang syntax, without the Elixir. prefix", ctx do
      logs = start_logs(ctx)
      :ok = Logs.subscribe(logs)
      :ok = connect(ctx)
      eventually(fn -> Logs.info(logs).status == :streaming end)

      :ok =
        Fixture.log(ctx.node, :warning, "hi", [], %{
          mfa: {:"Elixir.MyApp.Worker", :handle_info, 2}
        })

      assert_receive {:beamdash_logs, {:entries, [e]}}, 3_000
      assert e.where == "MyApp.Worker:handle_info/2"
      assert e.raw =~ "[warning] MyApp.Worker:handle_info/2 hi"
    end

    test "starts streaming when the target is already connected", ctx do
      :ok = connect(ctx)
      logs = start_logs(ctx)
      eventually(fn -> Logs.info(logs).status == :streaming end)
      assert %{source: :direct, level: level} = Logs.info(logs)
      assert is_atom(level)
    end

    test "disconnecting stops the source and detaches the handler", ctx do
      logs = start_logs(ctx)
      :ok = connect(ctx)
      eventually(fn -> Logs.info(logs).status == :streaming end)
      assert :beamdash_logs in :erpc.call(ctx.node, :logger, :get_handler_ids, [])

      :ok = Target.disconnect(ctx.target)
      eventually(fn -> Logs.info(logs).source == nil end)
      assert %{status: :idle} = Logs.info(logs)
      refute :beamdash_logs in :erpc.call(ctx.node, :logger, :get_handler_ids, [])
    end

    test "clear empties the entries and tells subscribers", ctx do
      logs = start_logs(ctx)
      :ok = Logs.subscribe(logs)
      :ok = connect(ctx)
      eventually(fn -> Logs.info(logs).status == :streaming end)

      :ok = Fixture.log(ctx.node, :error, "boom")
      assert_receive {:beamdash_logs, {:entries, [_]}}, 3_000
      assert [_ | _] = Logs.entries(logs)

      assert :ok = Logs.clear(logs)
      assert_receive {:beamdash_logs, :cleared}
      assert [] = Logs.entries(logs)
    end

    test "previous/1 needs a kubectl source", ctx do
      logs = start_logs(ctx)
      :ok = connect(ctx)
      eventually(fn -> Logs.info(logs).status == :streaming end)
      assert {:error, :not_kubectl} = Logs.previous(logs)
    end
  end

  describe "kubectl source with the logger handler" do
    @history "printf '2026-10-23T12:00:00Z [info] one\\n2026-10-23T12:00:01Z [error] two\\n" <>
               "2026-10-23T12:00:01Z     at line 1\\n2099-01-01T00:00:00Z [info] after attach\\n'"

    test "recent output first, minus lines from after attaching, then handler events", ctx do
      logs =
        start_logs(ctx, source_fun: fn _ -> @kubectl end, logs_cmd: sh(@history))

      :ok = Logs.subscribe(logs)
      :ok = connect(ctx)
      eventually(fn -> Logs.info(logs).status == :streaming end)

      assert [two, one] = Logs.entries(logs)
      assert two.message == "two\n    at line 1"
      assert one.message == "one"
      assert %{source: :kubectl, kubectl: %{pod: "p"}, level: level} = Logs.info(logs)
      assert is_atom(level)

      :ok = Fixture.log(ctx.node, :warning, "from the handler")
      eventually(fn -> length(Logs.entries(logs)) == 3 end)

      assert [event, ^two, ^one] = Logs.entries(logs)
      assert event.level == :warning
      assert event.message == "from the handler"
      assert event.pid =~ ~r/^<\d+\.\d+\.\d+>$/
      assert event.id > two.id
    end

    test "unreadable history leaves just the handler's events", ctx do
      logs = start_logs(ctx, source_fun: fn _ -> @kubectl end, logs_cmd: sh("echo nope; exit 1"))
      :ok = connect(ctx)
      eventually(fn -> Logs.info(logs).status == :streaming end)
      assert [] = Logs.entries(logs)

      :ok = Fixture.log(ctx.node, :error, "boom")
      eventually(fn -> match?([%{message: "boom"}], Logs.entries(logs)) end)
      assert {:error, {1, "nope\n"}} = Logs.previous(logs)
    end
  end

  describe "kubectl source" do
    test "lines are parsed, continuations folded, and the end reported", ctx do
      logs = kubectl_logs(ctx, @script)

      eventually(fn -> Logs.info(logs).status == {:ended, 0} end)
      assert [two, one] = Logs.entries(logs)
      assert two.message == "two\n    at line 1"
      assert two.level == :error
      assert one.message == "one"
      assert two.id > one.id

      assert %{source: :kubectl, kubectl: %{namespace: "ns", pod: "p"}} = Logs.info(logs)
      assert_received {:beamdash_logs, {:info, %{status: {:ended, 0}}}}
    end

    test "reconnect runs the command again, ids keep increasing", ctx do
      logs = kubectl_logs(ctx, @script)
      eventually(fn -> Logs.info(logs).status == {:ended, 0} end)

      assert :ok = Logs.reconnect(logs)

      eventually(fn ->
        Logs.info(logs).status == {:ended, 0} and length(Logs.entries(logs)) == 4
      end)

      ids = Enum.map(Logs.entries(logs), & &1.id)
      assert ids == Enum.sort(ids, :desc)
      assert length(Enum.uniq(ids)) == 4
    end

    test "a continuation after a flush re-sends the entry with the same id", ctx do
      script =
        "printf '2026-10-23T12:00:01Z [error] two\\n'; sleep 0.4; " <>
          "printf '2026-10-23T12:00:01Z     at line 1\\n'"

      logs = kubectl_logs(ctx, script)

      assert_receive {:beamdash_logs, {:entries, [%{message: "two"} = first]}}, 3_000
      assert_receive {:beamdash_logs, {:entries, [again]}}, 3_000
      assert again.id == first.id
      assert again.message == "two\n    at line 1"

      eventually(fn -> Logs.info(logs).status == {:ended, 0} end)
      assert [^again] = Logs.entries(logs)
    end

    test "a line longer than the port's line buffer is joined", ctx do
      script = "head -c 20000 /dev/zero | tr '\\0' a; printf '\\n'"
      logs = kubectl_logs(ctx, script)

      eventually(fn -> Logs.info(logs).status == {:ended, 0} end)
      assert [e] = Logs.entries(logs)
      assert e.message == String.duplicate("a", 20_000)
    end

    test "invalid UTF-8 is replaced", ctx do
      logs = kubectl_logs(ctx, "printf 'bad \\377 byte\\n'")

      eventually(fn -> Logs.info(logs).status == {:ended, 0} end)
      assert [e] = Logs.entries(logs)
      assert String.valid?(e.message)
      assert String.valid?(e.raw)
      assert e.message =~ "bad "
      assert e.message =~ "\uFFFD"
    end

    test "a burst of lines keeps entries and batches within the cap", ctx do
      script = ~S|i=0; while [ $i -lt 2100 ]; do echo "[info] l$i"; i=$((i+1)); done|
      logs = kubectl_logs(ctx, script)

      eventually(fn -> Logs.info(logs).status == {:ended, 0} end)
      entries = Logs.entries(logs)
      assert length(entries) == 2000
      assert hd(entries).message == "l2099"

      assert Enum.all?(drain_batches([]), &(length(&1) <= 2000))
    end

    test "previous/1 runs the command and parses its output", ctx do
      logs = kubectl_logs(ctx, @script)
      eventually(fn -> Logs.info(logs).status == {:ended, 0} end)

      assert {:ok, [two, one]} = Logs.previous(logs)
      assert two.message == "two\n    at line 1"
      assert one.message == "one"
      assert two.id > one.id
    end

    test "previous/1 reports a failing command", ctx do
      logs = kubectl_logs(ctx, "echo nope; exit 3")
      eventually(fn -> Logs.info(logs).status == {:ended, 3} end)

      assert {:error, {3, "nope\n"}} = Logs.previous(logs)
    end

    # Elixir's default console format starts with "\n"
    @blank_script "printf '2026-10-23T12:00:00Z \\n" <>
                    "2026-10-23T12:00:00Z 08:00:00.001 request_id=A1 [info] GET /api 1\\n" <>
                    "\\n" <>
                    "2026-10-23T12:00:01Z    \\n" <>
                    "2026-10-23T12:00:01Z 08:00:00.002 request_id=A2 [info] GET /api 2\\n" <>
                    "2026-10-23T12:00:02Z \\n" <>
                    "2026-10-23T12:00:02Z 08:00:00.003 request_id=A3 [info] GET /api 3\\n" <>
                    "2026-10-23T12:00:03Z \\t\\n" <>
                    "2026-10-23T12:00:03Z 08:00:00.004 request_id=A4 [info] GET /api 4\\n" <>
                    "\\n'"

    test "blank lines make no entries and do not break grouping", ctx do
      logs = kubectl_logs(ctx, @blank_script)
      eventually(fn -> Logs.info(logs).status == {:ended, 0} end)

      entries = Logs.entries(logs)
      assert length(entries) == 4
      assert Enum.all?(entries, &(&1.level == :info))
      assert hd(entries).message == "GET /api 4"
      assert {"request_id", "A4"} in hd(entries).meta
      assert [%{count: 4}] = Beamdash.Logs.Group.group(entries)

      assert {:ok, previous} = Logs.previous(logs)
      assert length(previous) == 4
      assert [%{count: 4}] = Beamdash.Logs.Group.group(previous)
    end

    test "an ended stream keeps its status when the target then disconnects", ctx do
      logs = kubectl_logs(ctx, "echo bye; exit 7")
      eventually(fn -> Logs.info(logs).status == {:ended, 7} end)

      # Target tells Logs before it replies, so the info call below comes
      # after the disconnect was handled
      :ok = Target.disconnect(ctx.target)
      assert %{status: {:ended, 7}, source: :kubectl, kubectl: %{pod: "p"}} = Logs.info(logs)
      refute_received {:beamdash_logs, {:info, %{status: :idle}}}

      # the next connection starts the source again
      :ok = connect(ctx)
      assert_receive {:beamdash_logs, {:info, %{status: :streaming, source: :kubectl}}}, 3_000
      eventually(fn -> Logs.info(logs).status == {:ended, 7} end)
    end

    test "a missing kubectl ends the stream without crashing", ctx do
      logs =
        start_logs(ctx,
          source_fun: fn _ -> @kubectl end,
          logs_cmd: fn args -> {nil, args} end,
          kubectl_logger: false
        )

      :ok = connect(ctx)
      eventually(fn -> Logs.info(logs).status == {:ended, :kubectl_not_found} end)
      assert Process.alive?(logs)
      assert {:error, :kubectl_not_found} = Logs.previous(logs)
    end
  end
end
