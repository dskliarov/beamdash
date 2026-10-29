defmodule Beamdash.SourceBrowserTest do
  use ExUnit.Case, async: false
  alias Beamdash.SourceBrowser
  alias BeamdashWeb.ModulesLive

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "beamdash-source-browser-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(dir, "lib/nested"))
    File.write!(Path.join(dir, "mix.exs"), "# mix project")
    File.write!(Path.join(dir, "lib/demo.ex"), "defmodule Demo do end\n")
    File.write!(Path.join(dir, "lib/readme.txt"), "not source")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "lists folders and source files and rejects filenames outside the current folder", %{
    dir: dir
  } do
    browser = SourceBrowser.open(Path.join(dir, "lib"))
    assert browser.subdirs == ["nested"]
    assert browser.files == ["demo.ex"]

    assert {:ok, %{text: "defmodule Demo do end\n", language: "elixir"}} =
             SourceBrowser.load(browser, "demo.ex")

    assert {:error, _} = SourceBrowser.load(browser, "../mix.exs")
  end

  test "picking a file loads CodeMirror, updates its baseline and clears staged code", %{dir: dir} do
    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = ModulesLive.mount(%{}, %{}, socket)

    socket =
      Phoenix.Component.assign(socket,
        status: :connected,
        selected: Demo,
        source: "draft",
        compiled: "beam",
        candidate_result: "passed",
        browser: SourceBrowser.open(Path.join(dir, "lib"))
      )

    {:noreply, picked} =
      ModulesLive.handle_event("source_browse_pick", %{"name" => "demo.ex"}, socket)

    assert picked.assigns.source == "defmodule Demo do end\n"
    assert picked.assigns.project == dir
    assert picked.assigns.language == "elixir"
    assert picked.assigns.original.source == picked.assigns.source
    assert picked.assigns.editor_revision == socket.assigns.editor_revision + 1
    assert picked.assigns.compiled == nil
    assert picked.assigns.candidate_result == nil
    assert picked.assigns.browser == nil
    assert picked.assigns.source_file_found
  end

  test "missing source exposes the browse control and navigation can be cancelled", %{dir: dir} do
    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = ModulesLive.mount(%{}, %{}, socket)

    socket =
      Phoenix.Component.assign(socket,
        status: :connected,
        selected: Demo,
        project: dir,
        syntax: :elixir
      )

    html = socket.assigns |> ModulesLive.render() |> Phoenix.LiveViewTest.rendered_to_string()
    assert html =~ "Browse local source"
    {:noreply, opened} = ModulesLive.handle_event("browse_source_file", %{}, socket)
    assert opened.assigns.browser.path == dir

    {:noreply, entered} =
      ModulesLive.handle_event("source_browse_into", %{"name" => "lib"}, opened)

    assert entered.assigns.browser.files == ["demo.ex"]
    {:noreply, closed} = ModulesLive.handle_event("source_browse_close", %{}, entered)
    assert closed.assigns.browser == nil
  end

  test "bad or oversized files leave the current editor unchanged", %{dir: dir} do
    File.write!(Path.join(dir, "lib/bad.ex"), <<255>>)
    File.write!(Path.join(dir, "lib/large.ex"), String.duplicate("x", 2 * 1024 * 1024 + 1))
    browser = SourceBrowser.open(Path.join(dir, "lib"))
    assert {:error, _} = SourceBrowser.load(browser, "bad.ex")
    assert {:error, _} = SourceBrowser.load(browser, "large.ex")
    assert SourceBrowser.open(Path.join(dir, "missing")).error != nil

    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = ModulesLive.mount(%{}, %{}, socket)

    socket =
      Phoenix.Component.assign(socket,
        status: :connected,
        selected: Demo,
        source: "pending edits",
        compiled: "staged beam",
        browser: browser
      )

    {:noreply, failed} =
      ModulesLive.handle_event("source_browse_pick", %{"name" => "bad.ex"}, socket)

    assert failed.assigns.source == "pending edits"
    assert failed.assigns.compiled == "staged beam"
    assert failed.assigns.editor_revision == socket.assigns.editor_revision
    assert failed.assigns.browser.error =~ "UTF-8"
  end
end
