defmodule Exberly.ProcessDetailsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias ExberlyWeb.ProcessDetails

  test "queued messages keep their id while earlier ones are consumed" do
    ids = ProcessDetails.message_ids([:a, {:b, 1}, :a])
    assert [{a0, :a}, {b, {:b, 1}}, {a1, :a}] = ids
    assert length(Enum.uniq([a0, b, a1])) == 3
    # :a at the head is consumed: the others keep their ids
    assert [{^b, {:b, 1}}, {^a0, :a}] = ProcessDetails.message_ids([{:b, 1}, :a])
  end

  test "an opened message stays open when the panel refreshes" do
    detail =
      Map.merge(Exberly.Test.Fixture.gc_detail(), %{
        reductions: 1,
        links: [],
        monitors: [],
        monitored_by: [],
        current_stacktrace: [],
        trap_exit: false,
        priority: :normal,
        mailbox: %{length: 2, limit: 100, messages: [{:hello, 1}, :bye]}
      })

    html =
      render_component(&ProcessDetails.panel/1,
        details: detail,
        history: [],
        syntax: :erlang
      )

    [{id, _} | _] = ProcessDetails.message_ids([{:hello, 1}, :bye])
    assert html =~ ~s(<details id="#{id}")
    # the browser's "open" attribute is left alone by refreshes
    assert length(Regex.scan(~r/<details id="mq-[^"]+" phx-mounted="[^"]*ignore_attrs/, html)) ==
             2
  end

  test "links are drawn as on the Applications tab" do
    linked = spawn(fn -> Process.sleep(:infinity) end)
    port = Port.open({:spawn, "cat"}, [])
    on_exit(fn -> Process.exit(linked, :kill) end)

    detail =
      Map.merge(Exberly.Test.Fixture.gc_detail(), %{
        registered_name: :my_server,
        reductions: 1,
        links: [linked, port],
        monitors: [{:process, linked}],
        monitored_by: [],
        current_stacktrace: [],
        trap_exit: false,
        priority: :normal
      })

    html =
      render_component(&ProcessDetails.panel/1,
        details: detail,
        history: [],
        syntax: :erlang,
        names: %{linked => :worker_a}
      )

    esc =
      &(&1
        |> Exberly.Format.pid(:erlang)
        |> Phoenix.HTML.html_escape()
        |> Phoenix.HTML.safe_to_string())

    assert html =~ ~s(class="app-chart-scroll links-chart")
    assert html =~ ~s(aria-label="Linked processes")
    # this process: highlighted, not a link to itself
    assert html =~ ~r/<g class="app-box selected static"[^>]*>\s*<title>my_server/
    # a linked process opens on click; a port is shown but cannot be opened
    assert html =~
             ~r/<g class="app-box\s*"[^>]*phx-click="select"[^>]*phx-value-pid="#{Regex.escape(esc.(linked))}"/

    assert html =~ ">worker_a<" or html =~ "worker_a\n"
    assert html =~ ~r/<g class="app-box\s+static"/
    assert html =~ "#Port&lt;"
    # monitors stay a list, in the same boxes
    assert html =~ "Monitors"
    refute html =~ ~r/<dt>Links<\/dt>/
    Port.close(port)
  end
end
