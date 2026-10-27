defmodule Beamdash.LogsLiveTest do
  # The Logs tab against a real Beamdash.Logs fed by a fixed kubectl script.
  #
  # Phoenix.LiveViewTest's live/live_isolated need the optional lazy_html
  # dependency, which this project does not have, so (as in the Trace and GC
  # tests) the page's callbacks are called directly on a socket. The socket
  # has a transport pid, so the page subscribes this test process; after each
  # render the stream is pruned as LiveView does, so a render shows only the
  # rows sent since the previous one (a reset sends them all).
  use ExUnit.Case, async: false

  alias Beamdash.{Logs, Target}
  alias Beamdash.Test.Fixture
  alias BeamdashWeb.LogsLive
  alias Phoenix.LiveView.{Lifecycle, Socket, Utils}

  @moduletag :capture_log

  @kubectl {:kubectl, %{kubeconfig: nil, namespace: "ns", pod: "p", container: nil}}

  @lines [
    "[warning] cache miss for key user:1",
    "[warning] cache miss for key user:2",
    "[warning] cache miss for key user:3",
    "[error] boom",
    "[warning] cache miss for key user:4",
    "[warning] cache miss for key user:5",
    "[info] hello"
  ]

  @script "printf '" <>
            (@lines
             |> Enum.with_index(1)
             |> Enum.map_join(fn {line, i} ->
               "2026-10-23T12:00:0#{i}Z #{line}\\n"
             end)) <> "'"

  setup do
    {peer, node} = Fixture.start_peer()
    on_exit(fn -> Fixture.stop_peer(peer) end)

    id = System.unique_integer([:positive])
    target = start_supervised!({Target, name: :"lv_target_#{id}"}, id: :target)

    logs =
      start_supervised!(
        {Logs,
         name: :"lv_logs_#{id}",
         target: target,
         source_fun: fn _ -> @kubectl end,
         logs_cmd: fn _args -> {System.find_executable("sh"), ["-c", @script]} end},
        id: :logs
      )

    {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie(), target)
    eventually(fn -> Logs.info(logs).status == {:ended, 0} end)
    7 = length(Logs.entries(logs))

    %{logs: logs, target: target, node: node}
  end

  defp eventually(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_until(fun, deadline)
  end

  defp wait_until(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("condition not met in time")
      true -> Process.sleep(20) && wait_until(fun, deadline)
    end
  end

  defp mount(ctx) do
    socket = %Socket{
      transport_pid: self(),
      private: %{lifecycle: %Lifecycle{}, live_temp: %{}}
    }

    session = %{"logs_server" => ctx.logs, "target" => ctx.target}
    {:ok, socket} = LogsLive.mount(%{}, session, socket)
    socket
  end

  # {html, socket with the stream pruned}
  defp render(socket) do
    html = socket.assigns |> LogsLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    {html, Lifecycle.after_render(socket)}
  end

  defp event(socket, name, params \\ %{}) do
    {:noreply, socket} = LogsLive.handle_event(name, params, socket)
    socket
  end

  defp info(socket, message) do
    {:noreply, socket} = LogsLive.handle_info(message, socket)
    socket
  end

  # the streamed rows' DOM ids, in order
  defp row_ids(html), do: Regex.scan(~r/id="rows-([^"]+)"/, html) |> Enum.map(&List.last/1)

  # the text of each row's Message column, in order
  defp messages(html) do
    Regex.scan(~r/<span class="logs-msg"[^>]*>(.*?)<\/span>/s, html)
    |> Enum.map(fn [_, m] -> m |> String.replace(~r/<[^>]+>/, "") |> String.trim() end)
  end

  test "rows newest first, repeats grouped, with counts", ctx do
    {html, _} = ctx |> mount() |> render()

    assert messages(html) == [
             "hello",
             "cache miss for key user:5",
             "boom",
             "cache miss for key user:3"
           ]

    assert row_ids(html) == ["g-7", "g-5", "g-4", "g-1"]
    assert html =~ ~r/class="count-badge"[^>]*>\s*×2/
    assert html =~ ~r/class="count-badge"[^>]*>\s*×3/
    assert html =~ "7 of 7 lines"
    assert html =~ "kubectl logs"
    assert html =~ ~s(id="logs-page")
    assert html =~ ~s(phx-hook="LogExport")
    assert html =~ ~s(id="logs-filter")
    assert html =~ ~s(phx-debounce="250")
    assert html =~ "Stream ended (exit 0)"
    assert html =~ ~s(phx-click="reconnect")
    assert html =~ "Previous container"
  end

  test "the text filter keeps matching lines and highlights the terms", ctx do
    {_, socket} = ctx |> mount() |> render()
    {html, _} = socket |> event("filter", %{"q" => "cache -user:5"}) |> render()

    assert html =~ "4 of 7 lines"
    assert html =~ "<mark>cache</mark>"
    assert messages(html) == ["cache miss for key user:4"]
    # boom no longer separates the runs, so user:4 joins user:1..3
    assert row_ids(html) == ["g-1"]
    assert html =~ ~r/class="count-badge"[^>]*>\s*×4/
  end

  test "the level filter", ctx do
    {_, socket} = ctx |> mount() |> render()
    {html, socket} = socket |> event("level", %{"level" => "error"}) |> render()

    assert messages(html) == ["boom"]
    assert html =~ "1 of 7 lines"

    {html, _} = socket |> event("level", %{"level" => ""}) |> render()
    assert html =~ "7 of 7 lines"
  end

  test "picking a level says how many lines have no readable level", ctx do
    {_, socket} = ctx |> mount() |> render()
    unreadable = %{new_entry(8, "made-up format line") | level: nil}

    {html, socket} =
      socket
      |> info({:beamdash_logs, {:entries, [unreadable]}})
      |> event("level", %{"level" => "info"})
      |> render()

    assert html =~ "7 of 8 lines"
    assert html =~ "1 of 8 lines have no level"

    {html, _} = socket |> event("level", %{"level" => ""}) |> render()
    refute html =~ "have no level"
  end

  test "Group repeats off shows every line", ctx do
    {_, socket} = ctx |> mount() |> render()
    {html, socket} = socket |> event("toggle_group") |> render()

    assert row_ids(html) == ~w(e-7 e-6 e-5 e-4 e-3 e-2 e-1)
    refute html =~ "count-badge"
    assert html =~ "7 of 7 lines"

    {html, _} = socket |> event("toggle_group") |> render()
    assert row_ids(html) == ["g-7", "g-5", "g-4", "g-1"]
  end

  test "expanding a group lists its original lines, masked parts marked", ctx do
    {_, socket} = ctx |> mount() |> render()
    {html, socket} = socket |> event("toggle_row", %{"id" => "g-1"}) |> render()

    # only the expanded row is sent again
    assert row_ids(html) == ["g-1"]
    assert html =~ ~s(aria-expanded="true")

    for n <- 1..3 do
      assert html =~ ~s(user:<span class="var">#{n}</span>)
    end

    # a line's metadata opens on click
    {html, socket} = socket |> event("toggle_entry", %{"id" => "2", "row" => "g-1"}) |> render()
    assert html =~ ~s(class="props")
    assert html =~ "<pre>cache miss for key user:2</pre>"

    {html, _} = socket |> event("toggle_row", %{"id" => "g-1"}) |> render()
    assert row_ids(html) == ["g-1"]
    refute html =~ ~s(class="var")
  end

  test "a single line opens its full message and metadata", ctx do
    {_, socket} = ctx |> mount() |> render()
    {html, _} = socket |> event("toggle_entry", %{"id" => "4", "row" => "g-4"}) |> render()

    assert row_ids(html) == ["g-4"]
    assert html =~ "<pre>boom</pre>"
    assert html =~ ~s(class="props")
  end

  test "Show all like this sets a pattern; the chip clears it", ctx do
    {_, socket} = ctx |> mount() |> render()
    {html, socket} = socket |> event("like", %{"id" => "g-5"}) |> render()

    assert row_ids(html) == ~w(e-6 e-5 e-3 e-2 e-1)
    assert html =~ "5 of 7 lines"
    assert html =~ "pattern:"
    assert html =~ "cache miss for key user:#"
    assert html =~ ~s(aria-label="Remove pattern filter")
    refute html =~ "boom"

    {html, _} = socket |> event("clear_pattern") |> render()
    refute html =~ "pattern:"
    assert row_ids(html) == ["g-7", "g-5", "g-4", "g-1"]
  end

  test "Copy pushes a group's raw lines, oldest first", ctx do
    {_, socket} = ctx |> mount() |> render()
    socket = event(socket, "export", %{"id" => "g-1", "mode" => "copy"})

    assert [["logs-export", %{name: name, text: text, mode: "copy"}]] =
             Utils.get_push_events(socket)

    assert name =~ ~r/^#{Regex.escape(Atom.to_string(ctx.node))}-\d{8}-\d{6}\.log$/
    lines = String.split(text, "\n")
    assert length(lines) == 3

    for {line, n} <- Enum.with_index(lines, 1) do
      assert line =~ ~r/^2026-10-23T12:00:0#{n}Z \[warning\] cache miss for key user:#{n}$/
    end
  end

  test "Download all pushes every line passing the filters", ctx do
    {_, socket} = ctx |> mount() |> render()

    socket =
      socket
      |> event("level", %{"level" => "warning"})
      |> event("export", %{"id" => "all", "mode" => "download"})

    assert [["logs-export", %{text: text, mode: "download"}]] = Utils.get_push_events(socket)
    lines = String.split(text, "\n")
    assert length(lines) == 6
    assert hd(lines) =~ "user:1"
    assert Enum.at(lines, 3) =~ "[error] boom"
    assert List.last(lines) =~ "user:5"
  end

  defp new_entry(id, message) do
    %{
      id: id,
      at: ~U[2026-10-23 12:00:09.123456Z],
      level: :info,
      pid: nil,
      where: nil,
      message: message,
      meta: [],
      raw: "2026-10-23T12:00:09.123456Z [info] #{message}"
    }
  end

  test "new lines arrive at the top; a similar one joins the top row", ctx do
    {_, socket} = ctx |> mount() |> render()

    {html, socket} =
      socket |> info({:beamdash_logs, {:entries, [new_entry(8, "hello")]}}) |> render()

    assert row_ids(html) == ["g-7"]
    assert html =~ ~r/class="count-badge"[^>]*>\s*×2/
    assert html =~ "8 of 8 lines"
    assert html =~ "12:00:09.123"

    {html, _} =
      socket |> info({:beamdash_logs, {:entries, [new_entry(9, "other")]}}) |> render()

    assert row_ids(html) == ["g-9"]
    assert html =~ "9 of 9 lines"
  end

  test "a pid links to its process while a node is attached", ctx do
    {_, socket} = ctx |> mount() |> render()
    init = :erpc.call(ctx.node, :erlang, :whereis, [:init])
    local = Beamdash.Format.pid(init, :erlang)
    printed = Target.localize_pid("<0.86.0>", ctx.node)
    refute printed == "<0.86.0>"

    entries = [
      %{new_entry(8, "from the handler") | pid: local},
      %{new_entry(9, "from a text line") | pid: "<0.86.0>"},
      %{new_entry(10, "from an Elixir line") | pid: "#PID<0.86.0>"},
      %{new_entry(11, "not a pid") | pid: "worker"}
    ]

    {html, socket} = socket |> info({:beamdash_logs, {:entries, entries}}) |> render()
    href = &~s(href="/?pid=#{URI.encode_www_form(&1)}")
    shown = local |> String.replace("<", "&lt;") |> String.replace(">", "&gt;")
    assert html =~ ~r/#{Regex.escape(href.(local))}[^>]*>#{shown}</
    assert html =~ ~r/#{Regex.escape(href.(printed))}[^>]*>&lt;0.86.0&gt;</
    assert html =~ ~r/#{Regex.escape(href.(printed))}[^>]*>#PID&lt;0.86.0&gt;</
    assert html =~ ~r/<span>worker<\/span>/

    {html, _} =
      socket
      |> Phoenix.Component.assign(status: :disconnected)
      |> info({:beamdash_logs, {:entries, [%{new_entry(12, "detached") | pid: local}]}})
      |> render()

    refute html =~ "proc-link"
  end

  # a Logs that starts empty, so the test's own entries number from 1
  defp empty_logs(ctx) do
    id = System.unique_integer([:positive])

    logs =
      start_supervised!(
        {Logs,
         name: :"lv_empty_logs_#{id}",
         target: ctx.target,
         source_fun: fn _ -> @kubectl end,
         logs_cmd: fn _args -> {System.find_executable("sh"), ["-c", "true"]} end},
        id: :empty_logs
      )

    eventually(fn -> Logs.info(logs).status == {:ended, 0} end)
    [] = Logs.entries(logs)
    %{ctx | logs: logs}
  end

  defp similar(id), do: %{new_entry(id, "cache miss for key user:#{id}") | level: :warning}
  defp boom(id), do: %{new_entry(id, "boom") | level: :error}

  # entries first..last (similar) sent in batches (newest first) of `size`,
  # rendering after each; {the last render, socket}
  defp feed(socket, first, last, size) do
    first..last
    |> Enum.chunk_every(size)
    |> Enum.reduce({"", socket}, fn ids, {_, socket} ->
      batch = ids |> Enum.reverse() |> Enum.map(&similar/1)
      socket |> info({:beamdash_logs, {:entries, batch}}) |> render()
    end)
  end

  defp stream_ops(socket), do: socket.assigns.streams.rows

  test "a batch of similar lines is folded, then inserted once", ctx do
    {_, socket} = ctx |> empty_logs() |> mount() |> render()
    socket = info(socket, {:beamdash_logs, {:entries, Enum.map(3..1//-1, &similar/1)}})

    assert [{"rows-g-1", 0, %{count: 3}, _, _}] = stream_ops(socket).inserts

    {html, socket} = render(socket)
    assert row_ids(html) == ["g-1"]
    assert html =~ ~r/class="count-badge"[^>]*>\s*×3/

    # a mixed batch: the top row joined, then two new rows, each sent once
    batch = [similar(6), boom(5), similar(4)]
    socket = info(socket, {:beamdash_logs, {:entries, batch}})
    assert Enum.map(stream_ops(socket).inserts, &elem(&1, 0)) == ~w(rows-g-6 rows-g-5 rows-g-1)
    {html, _} = render(socket)
    assert html =~ ~r/class="count-badge"[^>]*>\s*×4/
  end

  test "rows keep working when lines leave the 2,000-line buffer", ctx do
    {_, socket} = ctx |> empty_logs() |> mount() |> render()
    {html, socket} = feed(socket, 1, 2_005, 401)

    # the top row is trimmed to the kept lines and keeps its DOM id
    assert row_ids(html) == ["g-1"]
    assert html =~ ~r/class="count-badge"[^>]*>\s*×2000/
    assert html =~ "2000 of 2000 lines"
    assert html =~ ~s(phx-value-entry="2005")
    top = socket.assigns.top_row
    assert top.id == "g-1" and top.count == 2_000 and length(top.ids) == 2_000
    assert {hd(top.ids), List.last(top.ids)} == {2_005, 6}

    # Expand, by the page's row id (Group.group/1 now gives g-6)
    {html, socket} =
      socket |> event("toggle_row", %{"id" => "g-1", "entry" => "2005"}) |> render()

    assert row_ids(html) == ["g-1"]
    assert html =~ ~s(aria-expanded="true")
    assert html =~ ~s(user:<span class="var">6</span>)
    refute html =~ ~s(user:<span class="var">5</span>)

    # Copy: the 2,000 kept lines, oldest first
    socket = event(socket, "export", %{"id" => "g-1", "entry" => "2005", "mode" => "copy"})
    assert [["logs-export", %{text: text, lines: 2_000}]] = Utils.get_push_events(socket)
    lines = String.split(text, "\n")
    assert length(lines) == 2_000
    assert hd(lines) =~ ~r/user:6$/
    assert List.last(lines) =~ ~r/user:2005$/

    # Show all like this
    {html, socket} = socket |> event("like", %{"id" => "g-1", "entry" => "2005"}) |> render()
    assert html =~ "2000 of 2000 lines"
    assert html =~ "pattern:"
    {html, socket} = socket |> event("clear_pattern") |> render()

    # after the reset the row is g-6, still expanded (the state follows the
    # group's newest line at expand time, not only its row id)
    assert row_ids(html) == ["g-6"]
    assert html =~ ~s(aria-expanded="true")
    assert html =~ ~s(user:<span class="var">2005</span>)

    # one more line joins it, still 2,000
    {html, socket} = feed(socket, 2_006, 2_006, 1)
    assert row_ids(html) == ["g-6"]
    assert html =~ ~r/class="count-badge"[^>]*>\s*×2000/
    assert length(socket.assigns.top_row.ids) == 2_000
  end

  test "a rendered row whose lines were all evicted is deleted", ctx do
    {_, socket} = ctx |> empty_logs() |> mount() |> render()
    {_, socket} = feed(socket, 1, 10, 10)
    {_, socket} = socket |> info({:beamdash_logs, {:entries, [boom(11)]}}) |> render()
    {_, socket} = feed(socket, 12, 2_000, 1_989)

    # 1..10 are evicted, the oldest kept row (boom) stays
    socket = info(socket, {:beamdash_logs, {:entries, Enum.map(2_010..2_001//-1, &similar/1)}})
    assert stream_ops(socket).deletes == ["rows-g-1"]
    assert Map.values(socket.assigns.row_ends) |> Enum.sort() == ["g-11", "g-12"]
    {html, socket} = render(socket)
    assert html =~ "2000 of 2000 lines"

    # then boom
    socket = info(socket, {:beamdash_logs, {:entries, [similar(2_011)]}})
    assert stream_ops(socket).deletes == ["rows-g-11"]
    assert Map.values(socket.assigns.row_ends) == ["g-12"]
    {_, socket} = render(socket)

    # the oldest rendered row's lines are trimmed too (12 is evicted)
    socket = info(socket, {:beamdash_logs, {:entries, [boom(2_012)]}})
    # each sent once, g-12 then g-2012 at 0 (the newest on top); the
    # oldest row was the top row, so it is not sent a second time
    assert [{"rows-g-2012", 0, _, _, _}, {"rows-g-12", 0, %{count: 1999}, _, _}] =
             stream_ops(socket).inserts

    {html, _} = render(socket)
    assert Enum.sort(row_ids(html)) == ["g-12", "g-2012"]
    assert html =~ ~r/class="count-badge"[^>]*>\s*×1999/
  end

  test "snapshots of expanded rows that were deleted are dropped", ctx do
    {_, socket} = ctx |> empty_logs() |> mount() |> render()
    {_, socket} = feed(socket, 1, 10, 10)
    {_, socket} = socket |> info({:beamdash_logs, {:entries, [boom(11)]}}) |> render()
    {_, socket} = feed(socket, 12, 2_000, 1_989)

    # expand the oldest group (1..10) and the newest one
    {_, socket} = socket |> event("toggle_row", %{"id" => "g-1"}) |> render()
    {_, socket} = socket |> event("toggle_row", %{"id" => "g-12"}) |> render()
    assert Map.keys(socket.assigns.expanded) |> Enum.sort() == ["g-1", "g-12"]

    # all of 1..10 are evicted: the row is deleted, its snapshot goes too
    socket = info(socket, {:beamdash_logs, {:entries, Enum.map(2_010..2_001//-1, &similar/1)}})
    assert stream_ops(socket).deletes == ["rows-g-1"]
    assert Map.keys(socket.assigns.expanded) == ["g-12"]
    {html, _} = render(socket)
    assert html =~ ~s(aria-expanded="true")
  end

  test "an expanded group keeps its lines while newer similar ones arrive", ctx do
    {_, socket} = ctx |> empty_logs() |> mount() |> render()
    {_, socket} = feed(socket, 1, 3, 3)
    {html, socket} = socket |> event("toggle_row", %{"id" => "g-1"}) |> render()
    assert html =~ ~s(aria-expanded="true")

    {html, socket} = feed(socket, 4, 6, 3)
    assert row_ids(html) == ["g-1"]
    # the header has the new count and newest text
    assert html =~ ~r/class="count-badge"[^>]*>\s*×6/
    assert messages(html) == ["cache miss for key user:6"]
    # the block still lists the lines it was expanded with
    for n <- 1..3, do: assert(html =~ ~s(user:<span class="var">#{n}</span>))
    for n <- 4..6, do: refute(html =~ ~s(user:<span class="var">#{n}</span>))
    assert html =~ "+3 newer"
    assert html =~ ~s(phx-click="refresh_row")

    {html, _} = socket |> event("refresh_row", %{"id" => "g-1", "entry" => "6"}) |> render()
    assert row_ids(html) == ["g-1"]
    for n <- 1..6, do: assert(html =~ ~s(user:<span class="var">#{n}</span>))
    refute html =~ "newer"
  end

  defp hit(id), do: %{new_entry(id, "cache hit") | level: :warning}

  test "evicting lines the oldest rendered row does not have leaves it alone", ctx do
    {_, socket} = ctx |> empty_logs() |> mount() |> render()
    {_, socket} = socket |> event("filter", %{"q" => "cache"}) |> render()

    # hidden boom 1..5, then rows: user 6..10 (oldest), hit 11, user 12..2000
    batch = Enum.map(1..5, &boom/1) ++ Enum.map(6..10, &similar/1) ++ [hit(11)]
    {_, socket} = socket |> info({:beamdash_logs, {:entries, Enum.reverse(batch)}}) |> render()
    {html, socket} = feed(socket, 12, 2_000, 1_989)
    assert html =~ "1995 of 2000 lines"

    # evicts boom 1, which no rendered row shows: only the top row is sent
    socket = info(socket, {:beamdash_logs, {:entries, [similar(2_001)]}})
    assert Enum.map(stream_ops(socket).inserts, &elem(&1, 0)) == ["rows-g-12"]
    {_, socket} = render(socket)

    # boom 2..5 go, then user 6: the oldest row is trimmed and sent
    socket = info(socket, {:beamdash_logs, {:entries, Enum.map(2_006..2_002//-1, &similar/1)}})

    assert {"rows-g-6", _, %{count: 4}, _, _} =
             List.keyfind(stream_ops(socket).inserts, "rows-g-6", 0)
  end

  test "Copy feedback from the hook shows until the next event", ctx do
    {_, socket} = ctx |> mount() |> render()

    {html, socket} =
      socket |> event("export_done", %{"ok" => true, "lines" => 3}) |> render()

    assert html =~ "Copied 3 lines"

    {html, socket} = socket |> event("toggle_row", %{"id" => "g-1"}) |> render()
    refute html =~ "Copied"

    {html, socket} = socket |> event("export_done", %{"ok" => false, "lines" => 3}) |> render()
    assert html =~ "Copy failed"
    refute html =~ "HTTPS"

    {html, socket} =
      socket |> event("export_done", %{"ok" => false, "reason" => "no_clipboard"}) |> render()

    assert html =~ "Copy failed: the clipboard needs HTTPS or localhost"

    # as strings, as a hook may send them
    {html, socket} =
      socket |> event("export_done", %{"ok" => "true", "lines" => "1"}) |> render()

    assert html =~ "Copied 1 line"

    # a malformed payload does not crash the page
    {html, socket} = socket |> event("export_done", %{"lines" => 2}) |> render()
    assert html =~ "Copy failed"
    {html, _} = socket |> event("export_done", "junk") |> render()
    assert html =~ "Copy failed"
  end

  test "an entry sent again (a continuation) resets the rows", ctx do
    {_, socket} = ctx |> mount() |> render()
    again = %{new_entry(4, "boom\n  at line 1") | level: :error}
    {html, _} = socket |> info({:beamdash_logs, {:entries, [again]}}) |> render()

    # every row is sent again, from Logs.entries
    assert row_ids(html) == ["g-7", "g-5", "g-4", "g-1"]
  end

  test "while paused new lines are counted, Resume shows them", ctx do
    {_, socket} = ctx |> mount() |> render()
    {html, socket} = socket |> event("pause") |> render()
    assert html =~ "Resume"

    {html, socket} =
      socket |> info({:beamdash_logs, {:entries, [new_entry(100, "late")]}}) |> render()

    assert html =~ "+1 new"
    assert row_ids(html) == []

    {html, _} = socket |> event("resume") |> render()
    assert html =~ "Pause"
    refute html =~ "+1 new"
    assert row_ids(html) == ["g-7", "g-5", "g-4", "g-1"]
  end

  test "a filter matching nothing says so, with Clear filter", ctx do
    {_, socket} = ctx |> mount() |> render()
    {html, socket} = socket |> event("filter", %{"q" => "nothing-like-this"}) |> render()

    assert html =~ "No lines match the filter"
    assert html =~ "0 of 7 lines"

    {html, _} = socket |> event("clear_filter") |> render()
    refute html =~ "No lines match the filter"
    assert html =~ "7 of 7 lines"
  end

  test "Clear empties the log", ctx do
    {_, socket} = ctx |> mount() |> render()
    {html, _} = socket |> event("clear") |> render()

    assert html =~ "0 of 0 lines"
    assert row_ids(html) == []
    assert Logs.entries(ctx.logs) == []
  end

  test "Previous container loads in the background, in its own rows", ctx do
    {_, socket} = ctx |> mount() |> render()
    {html, socket} = socket |> event("view", %{"view" => "previous"}) |> render()
    assert html =~ "Loading previous container…"

    assert_receive {:phoenix, :async_result, {:start, {_ref, nil, :previous, result}}}, 5_000
    {:noreply, socket} = LogsLive.handle_async(:previous, result, socket)
    {html, socket} = render(socket)

    refute html =~ "Loading previous container…"
    assert row_ids(html) == ["p-g-7", "p-g-5", "p-g-4", "p-g-1"]
    assert html =~ "7 of 7 lines"

    # live lines do not show in the Previous view
    {html, socket} =
      socket |> info({:beamdash_logs, {:entries, [new_entry(8, "live")]}}) |> render()

    assert row_ids(html) == []

    {html, _} = socket |> event("view", %{"view" => "live"}) |> render()
    assert row_ids(html) == ["g-8", "g-7", "g-5", "g-4", "g-1"]
  end

  test "a failing Previous container load shows the error", ctx do
    {_, socket} = ctx |> mount() |> render()
    socket = event(socket, "view", %{"view" => "previous"})
    {:noreply, socket} = LogsLive.handle_async(:previous, {:ok, {:error, {1, "no"}}}, socket)
    {html, _} = render(socket)

    assert html =~ "Could not load the previous container"
    assert row_ids(html) == []

    {:noreply, socket} = LogsLive.handle_async(:previous, {:exit, :boom}, socket)
    {html, _} = render(socket)
    assert html =~ "Could not load the previous container"
  end

  defp async_result(socket, key) do
    assert_receive {:phoenix, :async_result, {:start, {_ref, nil, ^key, result}}}, 5_000
    {:noreply, socket} = LogsLive.handle_async(key, result, socket)
    socket
  end

  # the <select> of one application's level, and its selected option
  defp app_level(html, app) do
    [_, select] =
      Regex.run(~r/<select[^>]*name="level"[^>]*data-app="#{app}"[^>]*>(.*?)<\/select>/s, html)

    [_, value] = Regex.run(~r/<option[^>]*value="([^"]*)"[^>]*selected/, select)
    value
  end

  test "App levels lists the node's applications and sets one", ctx do
    {html, socket} = ctx |> mount() |> render()
    refute html =~ "logs-app-levels"

    {html, socket} = socket |> event("toggle_app_levels") |> render()
    assert html =~ "Loading application levels…"

    {html, socket} = socket |> async_result(:app_levels) |> render()
    assert html =~ ~s(id="logs-app-levels")
    assert app_level(html, "kernel") == "default"
    assert app_level(html, "stdlib") == "default"
    assert html =~ "primary level"

    socket = event(socket, "set_app_level", %{"app" => "stdlib", "level" => "debug"})

    {html, socket} =
      socket |> async_result(:set_app_level) |> async_result(:app_levels) |> render()

    assert app_level(html, "stdlib") == "debug"
    assert html =~ "stdlib set to debug"
    assert [{:lists, :debug}] = :erpc.call(ctx.node, :logger, :get_module_level, [[:lists]])

    socket = event(socket, "set_app_level", %{"app" => "stdlib", "level" => "default"})

    {html, socket} =
      socket |> async_result(:set_app_level) |> async_result(:app_levels) |> render()

    assert app_level(html, "stdlib") == "default"
    assert [] = :erpc.call(ctx.node, :logger, :get_module_level, [[:lists]])

    {html, _} = socket |> event("toggle_app_levels") |> render()
    refute html =~ "logs-app-levels"
  end

  test "App levels ignores an application or level the node didn't list", ctx do
    {_, socket} = ctx |> mount() |> render()
    socket = socket |> event("toggle_app_levels") |> async_result(:app_levels)

    for params <- [
          %{"app" => "no_such_app_#{System.unique_integer([:positive])}", "level" => "debug"},
          %{"app" => "stdlib", "level" => "loud"},
          %{"app" => "stdlib"}
        ] do
      socket = event(socket, "set_app_level", params)
      refute_receive {:phoenix, :async_result, _}, 100
      {html, _} = render(socket)
      assert app_level(html, "stdlib") == "default"
    end
  end

  defp primary_level(html) do
    [_, select] =
      Regex.run(~r/<form[^>]*id="logs-primary-level".*?<select[^>]*>(.*?)<\/select>/s, html)

    [_, value] = Regex.run(~r/<option[^>]*value="([^"]*)"[^>]*selected/, select)
    value
  end

  test "App levels sets the node's primary level", ctx do
    {_, socket} = ctx |> mount() |> render()
    {html, socket} = socket |> event("toggle_app_levels") |> async_result(:app_levels) |> render()
    %{level: before} = :erpc.call(ctx.node, :logger, :get_primary_config, [])
    assert primary_level(html) == Atom.to_string(before)

    for params <- [%{"level" => "default"}, %{"level" => "loud"}, %{}] do
      _ = event(socket, "set_primary_level", params)
      refute_receive {:phoenix, :async_result, _}, 100
      assert %{level: ^before} = :erpc.call(ctx.node, :logger, :get_primary_config, [])
    end

    # the header's level, as a Direct stream reports it on attach
    socket = Phoenix.Component.assign(socket, info: %{socket.assigns.info | level: :notice})
    socket = event(socket, "set_primary_level", %{"level" => "debug"})

    {html, socket} =
      socket |> async_result(:set_primary_level) |> async_result(:app_levels) |> render()

    assert primary_level(html) == "debug"
    assert html =~ "Primary level set to debug"
    assert socket.assigns.info.level == :debug
    assert %{level: :debug} = :erpc.call(ctx.node, :logger, :get_primary_config, [])
  end

  test "App levels shows an error when the node can't be asked", ctx do
    {_, socket} = ctx |> mount() |> render()
    :ok = Target.disconnect(ctx.target)
    {html, _} = socket |> event("toggle_app_levels") |> async_result(:app_levels) |> render()
    assert html =~ "Could not read the application levels"
  end
end
