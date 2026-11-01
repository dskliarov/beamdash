defmodule Beamdash.NotebookLiveTest do
  use ExUnit.Case, async: false
  alias Beamdash.{Notebook, NotebookStore, Settings, Target}
  alias BeamdashWeb.NotebookLive

  setup do
    Target.disconnect()

    dir =
      Path.join(System.tmp_dir!(), "beamdash-notebook-view-#{System.unique_integer([:positive])}")

    old = Application.get_env(:beamdash, :notebooks_dir)
    Application.put_env(:beamdash, :notebooks_dir, dir)
    Settings.reload()

    on_exit(fn ->
      if old,
        do: Application.put_env(:beamdash, :notebooks_dir, old),
        else: Application.delete_env(:beamdash, :notebooks_dir)

      File.rm_rf(dir)
      Settings.reload()
    end)

    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = NotebookLive.mount(%{}, %{}, socket)
    %{socket: socket, dir: dir}
  end

  test "a listener that refuses shutdown blocks cell deletion and node changes", %{socket: socket} do
    cell = Enum.find(socket.assigns.notebook.blocks, & &1.executable)
    {:ok, _} = Application.ensure_all_started(:kino)
    {:ok, session} = Beamdash.Console.start(node(), self(), :elixir)
    on_exit(fn -> Beamdash.Console.stop(session) end)

    owner = self() |> :erlang.term_to_binary() |> Base.encode64()

    assert {:ok, %{status: :ok}} =
             Beamdash.Console.eval_cell(
               node(),
               session,
               cell.id,
               "owner = :erlang.binary_to_term(Base.decode64!(\"#{owner}\")); Kino.listen(5, fn _ -> Process.flag(:trap_exit, true); send(owner, :listener_ready); Process.sleep(10000) end)"
             )

    assert_receive :listener_ready, 2_000

    socket =
      Phoenix.Component.assign(socket,
        sessions: %{{:local, :elixir} => session},
        cell_targets: %{cell.id => :local},
        results: %{
          cell.id => %{
            status: :ok,
            output: "",
            result: "",
            execution_target: :local,
            execution_session: session
          }
        }
      )

    {:noreply, unchanged} =
      NotebookLive.handle_event(
        "execution_target",
        %{"cell_id" => cell.id, "target" => "remote"},
        socket
      )

    assert unchanged.assigns.cell_targets[cell.id] == :local
    assert unchanged.assigns.error =~ "Reset the notebook runtime"

    {:noreply, unchanged} =
      NotebookLive.handle_event("delete_cell", %{"id" => cell.id}, unchanged)

    assert Enum.any?(unchanged.assigns.notebook.blocks, &(&1.id == cell.id))
    assert unchanged.assigns.error =~ "Reset the notebook runtime"
  end

  test "reset clears runtime results and saved output blocks while preserving source", %{
    socket: socket
  } do
    source =
      "# Example\n\n```elixir\n1 + 1\n```\n\n<!-- livebook:{\"output\":true} -->\n\n```\nold output\n```\n"

    {:ok, notebook} = Notebook.from_livemd(source)
    cell = Enum.find(notebook.blocks, & &1.executable)
    assert Enum.any?(notebook.blocks, &(&1.kind == :output))
    {:ok, session} = Beamdash.Console.start(node(), self(), :elixir)
    on_exit(fn -> Beamdash.Console.stop(session) end)

    socket =
      Phoenix.Component.assign(socket,
        notebook: notebook,
        sessions: %{{:local, :elixir} => session},
        results: %{cell.id => %{status: :ok, output: "printed", result: "2"}},
        listener_output: "listener text",
        frame_updates: %{"frame" => {1, []}},
        chart_updates: %{"chart" => []},
        cell_targets: %{cell.id => :local},
        dirty: false
      )

    {:noreply, socket} = NotebookLive.handle_event("reset_notebook_runtime", %{}, socket)

    assert socket.assigns.results == %{}
    assert socket.assigns.listener_output == ""
    assert socket.assigns.sessions == %{}
    assert socket.assigns.frame_updates == %{}
    assert socket.assigns.chart_updates == %{}
    assert socket.assigns.cell_targets == %{cell.id => :local}
    assert socket.assigns.dirty
    assert Enum.any?(socket.assigns.notebook.blocks, &(&1.id == cell.id and &1.source == "1 + 1"))
    refute Enum.any?(socket.assigns.notebook.blocks, &(&1.kind == :output))
    refute Notebook.to_livemd(socket.assigns.notebook) =~ "old output"
  end

  test "execution targets are selected independently per cell", %{socket: socket} do
    notebook = Notebook.append(socket.assigns.notebook, :elixir)
    [first, second] = Enum.filter(notebook.blocks, & &1.executable)
    {:ok, local_session} = Beamdash.Console.start(node(), self(), :elixir)
    on_exit(fn -> Beamdash.Console.stop(local_session) end)

    socket =
      Phoenix.Component.assign(socket,
        notebook: notebook,
        sessions: %{{:local, :elixir} => local_session},
        results: %{
          first.id => %{
            status: :ok,
            result: "local",
            output: "",
            execution_target: :local,
            execution_session: local_session
          }
        }
      )

    assert socket.assigns.cell_targets == %{}

    {:noreply, socket} =
      NotebookLive.handle_event(
        "execution_target",
        %{"cell_id" => second.id, "target" => "local"},
        socket
      )

    assert socket.assigns.cell_targets == %{second.id => :local}
    assert socket.assigns.sessions[{:local, :elixir}] == local_session
    assert socket.assigns.results[first.id].status == :ok
    html = socket.assigns |> NotebookLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert length(Regex.scan(~r/aria-label="Run elixir cell on Beamdash node"/, html)) == 2

    {:reply, %{items: items}, _} =
      NotebookLive.handle_event(
        "complete",
        %{"cell_id" => second.id, "token" => "String.up"},
        socket
      )

    assert Enum.any?(items, &String.starts_with?(&1.label, "String.upcase"))

    {:noreply, socket} =
      NotebookLive.handle_info({:beamdash_target, {:disconnected, :nodedown}}, socket)

    assert socket.assigns.sessions[{:local, :elixir}] == local_session
    assert socket.assigns.results[first.id].status == :ok
    {:noreply, blocked} = NotebookLive.handle_event("run_cell", %{"id" => first.id}, socket)
    assert blocked.assigns.error =~ "Connect"
  end

  test "cell checkbox persists through save and reopening", %{socket: socket, dir: dir} do
    socket = Phoenix.Component.assign(socket, notebook_dir: dir)
    cell = Enum.find(socket.assigns.notebook.blocks, & &1.executable)

    {:noreply, socket} =
      NotebookLive.handle_event(
        "execution_target",
        %{"cell_id" => cell.id, "target" => "local"},
        socket
      )

    assert socket.assigns.dirty

    assert Notebook.execution_target(
             Enum.find(socket.assigns.notebook.blocks, &(&1.id == cell.id))
           ) == :local

    {:noreply, socket} =
      NotebookLive.handle_event("save_notebook", %{"filename" => "targets.livemd"}, socket)

    refute socket.assigns.dirty

    {:noreply, socket} =
      NotebookLive.handle_event("open_notebook", %{"name" => "targets.livemd"}, socket)

    reopened = Enum.find(socket.assigns.notebook.blocks, & &1.executable)
    assert socket.assigns.cell_targets[reopened.id] == :local
    html = socket.assigns |> NotebookLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ ~r/type="checkbox"[^>]*name="target"[^>]*value="local"[^>]*checked/

    {:noreply, socket} =
      NotebookLive.handle_event(
        "execution_target",
        %{"cell_id" => reopened.id, "target" => "remote"},
        socket
      )

    assert socket.assigns.dirty

    {:noreply, socket} =
      NotebookLive.handle_event("save_notebook", %{"filename" => "targets.livemd"}, socket)

    {:noreply, socket} =
      NotebookLive.handle_event("open_notebook", %{"name" => "targets.livemd"}, socket)

    reopened = Enum.find(socket.assigns.notebook.blocks, & &1.executable)
    assert socket.assigns.cell_targets[reopened.id] == :remote
  end

  test "frame updates are isolated by execution session even when frame IDs match", %{
    socket: socket
  } do
    notebook = Notebook.append(socket.assigns.notebook, :elixir)
    [first, second] = Enum.filter(notebook.blocks, & &1.executable)

    other =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(other, :stop) end)
    frame = %{type: :frame, id: "shared-ref", revision: 1, items: []}

    results = %{
      first.id => %{
        status: :ok,
        result: "",
        output: "",
        widget: frame,
        execution_target: :remote,
        execution_session: self()
      },
      second.id => %{
        status: :ok,
        result: "",
        output: "",
        widget: frame,
        execution_target: :local,
        execution_session: other
      }
    }

    socket =
      Phoenix.Component.assign(socket,
        notebook: notebook,
        sessions: %{{:remote, :elixir} => self(), {:local, :elixir} => other},
        results: results
      )

    {:noreply, socket} =
      NotebookLive.handle_info(
        {:beamdash_kino_frame, self(), "shared-ref", 2, [%{type: :text, text: "remote"}]},
        socket
      )

    assert socket.assigns.results[first.id].widget.items == [%{type: :text, text: "remote"}]
    assert socket.assigns.results[second.id].widget.items == []

    {:noreply, socket} =
      NotebookLive.handle_info(
        {:beamdash_kino_frame, other, "shared-ref", 2, [%{type: :text, text: "local"}]},
        socket
      )

    assert socket.assigns.results[second.id].widget.items == [%{type: :text, text: "local"}]
  end

  test "bundled Kino works in a local notebook session" do
    assert {:ok, session} = Beamdash.Console.start(node(), self(), :elixir)
    on_exit(fn -> Beamdash.Console.stop(session) end)

    assert {:ok, %{status: :ok, widget: %{type: :text, id: id}}} =
             Beamdash.Console.eval(
               node(),
               session,
               ~S|input = Kino.Input.text("Name", default: "Ada")|
             )

    assert {:ok, :ok} = Beamdash.Console.set_input(node(), session, id, "Grace")

    assert {:ok, %{result: ~S|"Grace"|}} =
             Beamdash.Console.eval(node(), session, "Kino.Input.read(input)")

    assert {:ok, %{result: result}} = Beamdash.Console.eval(node(), session, "node()")
    assert result =~ Atom.to_string(node())
  end

  test "edits, saves and reopens a notebook without evaluating code", %{socket: socket, dir: dir} do
    cell = Enum.find(socket.assigns.notebook.blocks, & &1.executable)

    {:noreply, edited} =
      NotebookLive.handle_event(
        "edit_cell",
        %{"cell_id" => cell.id, "source" => "x = 21"},
        socket
      )

    assert edited.assigns.dirty

    {:noreply, saved} =
      NotebookLive.handle_event("save_notebook", %{"filename" => "node.livemd"}, edited)

    refute saved.assigns.dirty
    assert {:ok, source, _} = NotebookStore.load("node.livemd", dir)
    assert source =~ "x = 21"

    {:noreply, opened} =
      NotebookLive.handle_event("open_notebook", %{"name" => "node.livemd"}, saved)

    assert Notebook.to_livemd(opened.assigns.notebook) == source
    assert opened.assigns.sessions == %{}
    assert opened.assigns.pending == nil
    html = opened.assigns |> NotebookLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "Download .livemd"
    assert html =~ "Run all"
  end

  test "changing folders refreshes the library and preserves the current notebook", %{
    socket: socket,
    dir: dir
  } do
    {:noreply, saved} =
      NotebookLive.handle_event("save_notebook", %{"filename" => "old.livemd"}, socket)

    next_dir = Path.join(dir, "next")
    assert {:ok, _} = NotebookStore.save("other.livemd", "# Other\n", :new, next_dir)
    {:noreply, same} = NotebookLive.handle_info({:beamdash_notebooks_dir, dir}, saved)
    refute same.assigns.dirty
    {:noreply, changed} = NotebookLive.handle_info({:beamdash_notebooks_dir, next_dir}, saved)
    assert changed.assigns.files == ["other.livemd"]
    assert changed.assigns.saved_name == nil
    assert changed.assigns.dirty

    assert Notebook.to_livemd(changed.assigns.notebook) ==
             Notebook.to_livemd(saved.assigns.notebook)

    {:noreply, opened} =
      NotebookLive.handle_event("open_notebook", %{"name" => "other.livemd"}, changed)

    assert opened.assigns.notebook.title == "Other"
  end

  test "disconnect preserves unsaved content and rejects cell execution", %{socket: socket} do
    cell = Enum.find(socket.assigns.notebook.blocks, & &1.executable)

    {:noreply, socket} =
      NotebookLive.handle_event(
        "edit_cell",
        %{"cell_id" => cell.id, "source" => "important draft"},
        socket
      )

    {:noreply, disconnected} =
      NotebookLive.handle_info({:beamdash_target, {:disconnected, :nodedown}}, socket)

    assert Notebook.to_livemd(disconnected.assigns.notebook) =~ "important draft"
    {:noreply, socket} = NotebookLive.handle_event("run_cell", %{"id" => cell.id}, disconnected)
    assert socket.assigns.error =~ "Connect"
    assert socket.assigns.sessions == %{}
  end

  test "renders a Kino text input with escaped label and value", %{socket: socket} do
    cell = Enum.find(socket.assigns.notebook.blocks, & &1.executable)

    result = %{
      status: :ok,
      output: "",
      result: "",
      widget: %{type: :text, id: "1", label: "<Name>", value: "Ada & Grace"}
    }

    socket = Phoenix.Component.assign(socket, results: %{cell.id => result})
    html = socket.assigns |> NotebookLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ ~s(phx-change="kino_text")
    assert html =~ "&lt;Name&gt;"
    assert html =~ "Ada &amp; Grace"
  end

  test "renders Kino select labels while sending indexes", %{socket: socket} do
    cell = Enum.find(socket.assigns.notebook.blocks, & &1.executable)

    result = %{
      status: :ok,
      output: "",
      result: "",
      widget: %{
        type: :select,
        id: "1",
        label: "Choice",
        value: 1,
        options: [{0, "<First>"}, {1, "Second"}]
      }
    }

    socket = Phoenix.Component.assign(socket, results: %{cell.id => result})
    html = socket.assigns |> NotebookLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "&lt;First&gt;"
    assert html =~ ~r/<option value="1" selected>\s*Second/s
  end

  test "renders Kino date and URL controls", %{socket: socket} do
    cell = Enum.find(socket.assigns.notebook.blocks, & &1.executable)

    date = %{
      status: :ok,
      output: "",
      result: "",
      widget: %{
        type: :date,
        id: "d",
        label: "Date",
        value: "2024-02-01",
        min: "2024-01-01",
        max: "2024-12-31"
      }
    }

    socket = Phoenix.Component.assign(socket, results: %{cell.id => date})
    html = socket.assigns |> NotebookLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ ~s(type="date")
    assert html =~ ~s(min="2024-01-01")

    url = %{
      status: :ok,
      output: "",
      result: "",
      widget: %{type: :url, id: "u", label: "URL", value: nil}
    }

    socket = Phoenix.Component.assign(socket, results: %{cell.id => url})
    html = socket.assigns |> NotebookLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ ~s(type="url")
  end

  test "renders a supported Kino image without an input form", %{socket: socket} do
    cell = Enum.find(socket.assigns.notebook.blocks, & &1.executable)

    result = %{
      status: :ok,
      output: "",
      result: "",
      widget: %{type: :image, mime: "image/png", data: "AQID"}
    }

    socket = Phoenix.Component.assign(socket, results: %{cell.id => result})
    html = socket.assigns |> NotebookLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ ~s(src="data:image/png;base64,AQID")

    refute html =~ ~s(phx-change="kino_text")
  end

  test "only displays listener output from the active session", %{socket: socket} do
    socket = Phoenix.Component.assign(socket, sessions: %{{:remote, :elixir} => self()})

    {:noreply, socket} =
      NotebookLive.handle_info({:beamdash_console_output, self(), "hello <world>"}, socket)

    assert socket.assigns.listener_output == "hello <world>"

    {:noreply, socket} =
      NotebookLive.handle_info({:beamdash_console_output, :other, "ignored"}, socket)

    assert socket.assigns.listener_output == "hello <world>"
    html = socket.assigns |> NotebookLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "hello &lt;world&gt;"
  end

  test "buffers a live chart event until its result arrives", %{socket: socket} do
    cell = Enum.find(socket.assigns.notebook.blocks, & &1.executable)
    ref = make_ref()

    socket =
      Phoenix.Component.assign(socket,
        sessions: %{{:remote, :elixir} => self()},
        pending: %{id: cell.id, ref: ref}
      )

    {:noreply, socket} =
      NotebookLive.handle_info(
        {:beamdash_kino_chart, self(), "chart", "push",
         %{data: [%{x: 1}], dataset: nil, window: nil}},
        socket
      )

    assert [%{event: "push"}] = socket.assigns.chart_updates["chart"]

    result = %{
      status: :ok,
      output: "",
      result: "",
      widget: %{type: :chart, id: "chart", spec: %{"mark" => "line"}, datasets: []}
    }

    {:noreply, socket} =
      NotebookLive.handle_async({:notebook_cell, ref}, {:ok, {:ok, result}}, socket)

    assert socket.assigns.chart_updates == %{}
    assert socket.assigns.results[cell.id].widget.id == "chart"
  end

  test "renders a VegaLite chart specification safely", %{socket: socket} do
    cell = Enum.find(socket.assigns.notebook.blocks, & &1.executable)

    result = %{
      status: :ok,
      output: "",
      result: "",
      widget: %{type: :chart, spec: %{"mark" => "bar", "title" => "<script>"}}
    }

    socket = Phoenix.Component.assign(socket, results: %{cell.id => result})
    html = socket.assigns |> NotebookLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ ~s(phx-hook="KinoChart")
    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>"
  end

  test "renders returned Kino markdown safely", %{socket: socket} do
    cell = Enum.find(socket.assigns.notebook.blocks, & &1.executable)

    result = %{
      status: :ok,
      output: "",
      result: "",
      widget: %{type: :markdown, text: "**bold** <script>alert(1)</script>"}
    }

    socket = Phoenix.Component.assign(socket, results: %{cell.id => result})
    html = socket.assigns |> NotebookLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "<strong>bold</strong>"
    refute html =~ "<script>"
  end

  test "updates and clears text frames for the active session", %{socket: socket} do
    cell = Enum.find(socket.assigns.notebook.blocks, & &1.executable)

    result = %{
      status: :ok,
      output: "",
      result: "",
      widget: %{type: :frame, id: "f", items: [%{type: :text, text: "old"}]}
    }

    socket =
      Phoenix.Component.assign(socket,
        sessions: %{{:remote, :elixir} => self()},
        results: %{cell.id => result}
      )

    {:noreply, socket} =
      NotebookLive.handle_info(
        {:beamdash_kino_frame, self(), "f", 1,
         [%{type: :text, text: "old"}, %{type: :image, mime: "image/png", data: "AQID"}]},
        socket
      )

    assert socket.assigns.results[cell.id].widget.items == [
             %{type: :text, text: "old"},
             %{type: :image, mime: "image/png", data: "AQID"}
           ]

    html = socket.assigns |> NotebookLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ ~s(src="data:image/png;base64,AQID")

    {:noreply, socket} =
      NotebookLive.handle_info(
        {:beamdash_kino_frame, self(), "f", 2,
         [%{type: :markdown, text: "**bold** <script>alert(1)</script>"}]},
        socket
      )

    html = socket.assigns |> NotebookLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "<strong>bold</strong>"
    refute html =~ "<script>"

    {:noreply, socket} =
      NotebookLive.handle_info({:beamdash_kino_frame, self(), "f", 3, []}, socket)

    assert socket.assigns.results[cell.id].widget.items == []
  end

  test "preserves a newer frame update arriving before the evaluation result", %{socket: socket} do
    cell = Enum.find(socket.assigns.notebook.blocks, & &1.executable)
    ref = make_ref()

    socket =
      Phoenix.Component.assign(socket,
        sessions: %{{:remote, :elixir} => self()},
        pending: %{id: cell.id, ref: ref}
      )

    newest = [%{type: :text, text: "latest"}]

    {:noreply, socket} =
      NotebookLive.handle_info({:beamdash_kino_frame, self(), "f", 3, newest}, socket)

    {:noreply, socket} =
      NotebookLive.handle_info({:beamdash_kino_frame, self(), "f", 2, []}, socket)

    response = %{
      status: :ok,
      output: "",
      result: "",
      widget: %{type: :frame, id: "f", revision: 1, items: []}
    }

    {:noreply, socket} =
      NotebookLive.handle_async({:notebook_cell, ref}, {:ok, {:ok, response}}, socket)

    assert socket.assigns.results[cell.id].widget.items == newest
    assert socket.assigns.results[cell.id].widget.revision == 3
    assert socket.assigns.frame_updates == %{}

    {:noreply, socket} =
      NotebookLive.handle_info({:beamdash_kino_frame, self(), "f", 2, []}, socket)

    assert socket.assigns.results[cell.id].widget.items == newest
  end

  test "renders nested frame controls with their widget identity", %{socket: socket} do
    cell = Enum.find(socket.assigns.notebook.blocks, & &1.executable)

    input = %{
      type: :interactive,
      widget: %{type: :text, id: "nested", label: "Name", value: "Ada"}
    }

    button = %{
      type: :interactive,
      widget: %{type: :button, id: "button", label: "Submit", value: ""}
    }

    result = %{
      status: :ok,
      output: "",
      result: "",
      widget: %{type: :frame, id: "frame", items: [input, button]}
    }

    socket = Phoenix.Component.assign(socket, results: %{cell.id => result})
    html = socket.assigns |> NotebookLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ ~s(name="widget_id" value="nested")
    assert html =~ ~s(phx-value-widget_id="button")
    assert html =~ ~s(value="Ada")
    assert html =~ "Submit"
  end

  test "renders interactive and rich layout items", %{socket: socket} do
    cell = Enum.find(socket.assigns.notebook.blocks, & &1.executable)

    widget = %{
      type: :layout,
      id: "layout",
      layout: :grid,
      columns: 2,
      active: 0,
      items: [
        %{type: :markdown, text: "**safe** <script>bad</script>"},
        %{type: :interactive, widget: %{type: :text, id: "field", label: "Name", value: "Ada"}},
        %{type: :image, mime: "image/png", data: "AQID"}
      ]
    }

    socket =
      Phoenix.Component.assign(socket,
        results: %{cell.id => %{status: :ok, output: "", result: "", widget: widget}}
      )

    html = socket.assigns |> NotebookLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "<strong>safe</strong>"
    refute html =~ "<script>"
    assert html =~ ~s(name="widget_id" value="field")
    assert html =~ ~s(src="data:image/png;base64,AQID")
  end

  test "nested frame updates render inside layouts", %{socket: socket} do
    cell = Enum.find(socket.assigns.notebook.blocks, & &1.executable)

    widget = %{
      type: :layout,
      id: "outer",
      layout: :grid,
      columns: 1,
      active: 0,
      items: [%{type: :frame, id: "inner", revision: 1, items: [%{type: :text, text: "before"}]}]
    }

    socket =
      Phoenix.Component.assign(socket,
        sessions: %{{:remote, :elixir} => self()},
        results: %{cell.id => %{status: :ok, output: "", result: "", widget: widget}}
      )

    {:noreply, socket} =
      NotebookLive.handle_info(
        {:beamdash_kino_frame, self(), "inner", 2, [%{type: :text, text: "after"}]},
        socket
      )

    html = socket.assigns |> NotebookLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "after"
    refute html =~ ">before<"

    {:noreply, socket} =
      NotebookLive.handle_info({:beamdash_kino_frame, self(), "inner", 1, []}, socket)

    assert [%{revision: 2, items: [%{text: "after"}]}] =
             socket.assigns.results[cell.id].widget.items
  end

  test "nested chart renders its Vega specification", %{socket: socket} do
    cell = Enum.find(socket.assigns.notebook.blocks, & &1.executable)

    widget = %{
      type: :frame,
      id: "parent",
      items: [%{type: :chart, id: "plot", spec: %{"mark" => "line"}, datasets: []}]
    }

    socket =
      Phoenix.Component.assign(socket,
        results: %{cell.id => %{status: :ok, output: "", result: "", widget: widget}}
      )

    html = socket.assigns |> NotebookLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ ~s(data-chart-id="plot")
    assert html =~ ~s(phx-hook="KinoChart")
  end

  test "nested layout tabs switch independently and retain controls", %{socket: socket} do
    cell = Enum.find(socket.assigns.notebook.blocks, & &1.executable)

    widget = %{
      type: :layout,
      id: "outer",
      layout: :grid,
      columns: 1,
      active: 0,
      items: [
        %{
          type: :layout,
          id: "inner",
          layout: :tabs,
          active: 0,
          labels: ["First", "Second"],
          items: [
            %{type: :text, text: "First content"},
            %{
              type: :interactive,
              widget: %{type: :text, id: "inside", label: "Name", value: "Ada"}
            }
          ]
        }
      ]
    }

    socket =
      Phoenix.Component.assign(socket,
        results: %{cell.id => %{status: :ok, output: "", result: "", widget: widget}}
      )

    html = socket.assigns |> NotebookLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "First content"
    assert html =~ ~s(name="widget_id" value="inside")
    assert html =~ ~s(role="tabpanel" hidden)

    {:noreply, socket} =
      NotebookLive.handle_event(
        "kino_layout_tab",
        %{"cell_id" => cell.id, "layout_id" => "inner", "index" => "1"},
        socket
      )

    html = socket.assigns |> NotebookLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ ~s(name="widget_id" value="inside")
    assert html =~ ~s(role="tabpanel" hidden)
  end

  test "renders text layout tabs and switches the visible item", %{socket: socket} do
    cell = Enum.find(socket.assigns.notebook.blocks, & &1.executable)

    widget = %{
      type: :layout,
      layout: :tabs,
      labels: ["First", "Second"],
      items: [%{type: :text, text: "Alpha"}, %{type: :text, text: "Beta"}],
      active: 0
    }

    socket =
      Phoenix.Component.assign(socket,
        results: %{cell.id => %{status: :ok, output: "", result: "", widget: widget}}
      )

    html = socket.assigns |> NotebookLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "Alpha"
    assert html =~ ~s(role="tabpanel" hidden)

    {:noreply, socket} =
      NotebookLive.handle_event(
        "kino_layout_tab",
        %{"cell_id" => cell.id, "index" => "1"},
        socket
      )

    html = socket.assigns |> NotebookLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "Beta"

    {:noreply, same} =
      NotebookLive.handle_event(
        "kino_layout_tab",
        %{"cell_id" => cell.id, "index" => "99"},
        socket
      )

    assert same.assigns.results[cell.id].widget.active == 1
  end

  test "a cleared Markdown cell remains editable and accepts replacement text", %{socket: socket} do
    {:noreply, socket} = NotebookLive.handle_event("add_cell", %{"kind" => "markdown"}, socket)

    cell =
      Enum.find(
        socket.assigns.notebook.blocks,
        &String.contains?(&1.source, "Write Markdown here.")
      )

    {:noreply, socket} =
      NotebookLive.handle_event("edit_cell", %{"cell_id" => cell.id, "source" => ""}, socket)

    html = socket.assigns |> NotebookLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ ~s(id="notebook-block-#{cell.id}")
    assert html =~ ~s(id="notebook-markdown-#{cell.id}")

    {:noreply, socket} =
      NotebookLive.handle_event(
        "edit_cell",
        %{"cell_id" => cell.id, "source" => "Replacement text"},
        socket
      )

    assert Enum.find(socket.assigns.notebook.blocks, &(&1.id == cell.id)).source ==
             "Replacement text"

    html = socket.assigns |> NotebookLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "Replacement text"
  end

  test "an error stops run-all and stale async responses are ignored", %{socket: socket} do
    cell = Enum.find(socket.assigns.notebook.blocks, & &1.executable)
    ref = make_ref()
    socket = Phoenix.Component.assign(socket, pending: %{id: cell.id, ref: ref}, queue: ["next"])

    {:noreply, socket} =
      NotebookLive.handle_async(
        {:notebook_cell, ref},
        {:ok, {:ok, %{status: :error, output: "", result: "failed"}}},
        socket
      )

    assert socket.assigns.queue == []
    assert socket.assigns.results[cell.id].status == :error

    {:noreply, after_stale} =
      NotebookLive.handle_async(
        {:notebook_cell, ref},
        {:ok, {:ok, %{status: :ok, output: "", result: "wrong"}}},
        socket
      )

    assert after_stale.assigns.results[cell.id].result == "failed"
  end
end
