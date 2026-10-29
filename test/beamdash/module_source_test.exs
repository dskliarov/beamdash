defmodule Beamdash.ModuleSourceTest do
  # A module's source, read on the node, and the source tabs of the Trace
  # and Profile tabs.
  use ExUnit.Case, async: false

  require Phoenix.LiveViewTest

  alias Beamdash.{ModuleSource, Target}
  alias Beamdash.Test.Fixture
  alias BeamdashWeb.{ProfileLive, SourceTabs, TraceLive}

  @source """
  -module(src_demo).
  -export([hello/1]).

  %% a comment only the source file has
  hello(Name) -> {hello, Name}.
  """

  setup do
    {peer, node} = Fixture.start_peer()
    on_exit(fn -> Fixture.stop_peer(peer) end)
    {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie())
    on_exit(fn -> Target.disconnect() end)
    %{node: node}
  end

  # loads `name` from `@source` (renamed) on `node`; returns the .erl path
  defp load(node, name, opts \\ [:debug_info]) do
    dir = Path.join(System.tmp_dir!(), "beamdash_src_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    src = Path.join(dir, "#{name}.erl")
    File.write!(src, String.replace(@source, "src_demo", Atom.to_string(name)))

    {:ok, ^name} =
      :compile.file(String.to_charlist(src), [outdir: String.to_charlist(dir)] ++ opts)

    true = :erpc.call(node, :code, :add_patha, [String.to_charlist(dir)])
    {:module, ^name} = :erpc.call(node, :code, :load_file, [name])
    src
  end

  test "the source file, when it is on the node", %{node: node} do
    src = load(node, :src_file_demo)

    assert {:ok, %{kind: :file, path: path, text: text, truncated: false}} =
             ModuleSource.get(node, :src_file_demo)

    assert path == src
    assert text =~ "%% a comment only the source file has"
  end

  test "rebuilt from debug info when the file is gone", %{node: node} do
    src = load(node, :src_debug_demo)
    File.rm!(src)

    assert {:ok, %{kind: :debug_info, path: ^src, text: text}} =
             ModuleSource.get(node, :src_debug_demo)

    assert text =~ "-module(src_debug_demo)."
    assert text =~ ~r/hello\(Name\) ->\s*\{hello, Name\}\./
    refute text =~ "a comment"
  end

  describe "a local source folder" do
    setup do
      on_exit(fn -> Beamdash.Settings.delete_source_dir("src_local_app") end)
      local = Path.join(System.tmp_dir!(), "beamdash_local_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(local) end)
      %{local: local}
    end

    test "has the source a release lacks", %{node: node, local: local} do
      # as in a release: no file on the node, no debug info
      src = load(node, :src_local_demo, [])
      text = File.read!(src)
      File.rm!(src)
      refute ModuleSource.available?(node, :src_local_demo)

      copy = Path.join([local, "src", "src_local_demo.erl"])
      File.mkdir_p!(Path.dirname(copy))
      File.write!(copy, text)
      :ok = Beamdash.Settings.put_source_dir("src_local_app", local)

      assert ModuleSource.available?(node, :src_local_demo)
      assert %{has_source: true} = Beamdash.Apps.module_summary(node, :src_local_demo)

      assert {:ok, %{kind: :local, path: ^copy, text: ^text, truncated: false}} =
               ModuleSource.get(node, :src_local_demo)

      assert SourceTabs.language(%{kind: :local, path: copy}) == "erlang"
    end

    test "is not used when the node has the file", %{node: node, local: local} do
      src = load(node, :src_local_file_demo)
      File.mkdir_p!(local)
      File.write!(Path.join(local, "src_local_file_demo.erl"), "a local copy")
      :ok = Beamdash.Settings.put_source_dir("src_local_app", local)

      assert {:ok, %{kind: :file, path: ^src}} = ModuleSource.get(node, :src_local_file_demo)
    end
  end

  test "available?: the file, or debug info to rebuild it from; a release has neither",
       %{node: node} do
    load(node, :src_avail_file)
    assert ModuleSource.available?(node, :src_avail_file)

    node |> load(:src_avail_debug) |> File.rm!()
    assert ModuleSource.available?(node, :src_avail_debug)

    # as in a release (mix release strips the beams): no file, no debug info
    node |> load(:src_avail_none, []) |> File.rm!()
    refute ModuleSource.available?(node, :src_avail_none)

    # the node asked through module_summary too, for the Apps and Processes tabs
    assert %{has_source: false} = Beamdash.Apps.module_summary(node, :src_avail_none)
    assert %{has_source: true} = Beamdash.Apps.module_summary(node, :src_avail_file)

    refute ModuleSource.available?(node, :no_such_module_here)
    refute ModuleSource.available?(nil, :src_avail_file)
  end

  test "neither: no file and no debug info, said in words", %{node: node} do
    src = load(node, :src_none_demo, [])
    File.rm!(src)

    assert {:ok, %{kind: :none, reason: :no_debug_info}} = ModuleSource.get(node, :src_none_demo)
    assert ModuleSource.reason(:no_debug_info) =~ "compiled without debug info"

    assert {:ok, %{kind: :none, reason: :not_loaded}} =
             ModuleSource.get(node, :no_such_module_here)
  end

  describe "source tabs" do
    defp page(view, node, modules) do
      socket = %Phoenix.LiveView.Socket{
        private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
      }

      {:ok, socket} = view.mount(%{}, %{}, socket)

      Phoenix.Component.assign(socket,
        syntax: :erlang,
        status: :connected,
        node: node,
        modules: modules
      )
    end

    defp event(socket, name, params) do
      {:noreply, socket} = socket.view.handle_event(name, params, socket)
      socket
    end

    defp html(socket) do
      socket.assigns
      |> Map.put(:socket, socket)
      |> socket.view.render()
      |> Phoenix.LiveViewTest.rendered_to_string()
    end

    test "open, switch between and close module sources on the Trace tab", %{node: node} do
      load(node, :src_tab_a)
      load(node, :src_tab_b)
      modules = [{:src_tab_a, [hello: 1], []}, {:src_tab_b, [hello: 1], []}]
      socket = %{page(TraceLive, node, modules) | view: TraceLive}

      # the Source button next to the selected module
      socket = event(socket, "select_module", %{"mod" => "src_tab_a"})
      assert html(socket) =~ ~r/<button[^>]*phx-click="open_source"[^>]*phx-value-mod="src_tab_a"/
      refute html(socket) =~ "src-tabs"

      socket = event(socket, "open_source", %{"mod" => "src_tab_a"})
      assert socket.assigns.source_tab == :src_tab_a
      h = html(socket)
      assert h =~ ~s(class="seg src-tabs")
      assert h =~ ~r/href="\/modules\?module=src_tab_a"[^>]*>\s*Edit/
      assert h =~ ~r/<button[^>]*aria-selected="false"[^>]*phx-value-tab="main"[^>]*>\s*Tracing/
      assert h =~ "a comment only the source file has"
      # one block for Highlight.js (Erlang, from the .erl), numbered 1 to 5
      assert h =~
               ~r/<code id="src-src_tab_a" class="language-erlang" phx-hook="Highlight" phx-update="ignore">-module\(src_tab_a\)/

      assert h =~ ~s(<pre class="src-nos" aria-hidden="true">1\n2\n3\n4\n5</pre>)
      # the page's own content is hidden, not removed (the log is a stream)
      assert h =~ ~r/<div hidden[^>]*>\s*<div class="trace-layout">/

      # a second one, and opening the first again only shows it
      socket = event(socket, "open_source", %{"mod" => "src_tab_b"})
      socket = event(socket, "open_source", %{"mod" => "src_tab_a"})
      assert Enum.map(socket.assigns.sources, & &1.mod) == [:src_tab_a, :src_tab_b]
      assert socket.assigns.source_tab == :src_tab_a

      # back to the page, then to a source
      socket = event(socket, "source_tab", %{"tab" => "main"})
      assert socket.assigns.source_tab == nil
      refute html(socket) =~ ~r/<div hidden/
      socket = event(socket, "source_tab", %{"tab" => "src_tab_b"})
      assert socket.assigns.source_tab == :src_tab_b

      # closing the one shown shows its neighbour; the last one shows the page
      socket = event(socket, "close_source", %{"mod" => "src_tab_b"})
      assert socket.assigns.source_tab == :src_tab_a
      socket = event(socket, "close_source", %{"mod" => "src_tab_a"})
      assert socket.assigns.sources == [] and socket.assigns.source_tab == nil
      refute html(socket) =~ "src-tabs"

      # only modules of the page's list: no atom is made from the text
      socket =
        event(socket, "open_source", %{"mod" => "src_tab_unknown_#{System.unique_integer()}"})

      assert socket.assigns.sources == []
    end

    test "no Source button for a module without a source (as on a release)", %{node: node} do
      node |> load(:src_tab_none, []) |> File.rm!()
      load(node, :src_tab_ok)
      modules = [{:src_tab_none, [hello: 1], []}, {:src_tab_ok, [hello: 1], []}]

      trace = %{page(TraceLive, node, modules) | view: TraceLive}
      trace = event(trace, "select_module", %{"mod" => "src_tab_none"})
      refute html(trace) =~ ~s(phx-click="open_source")
      trace = event(trace, "select_module", %{"mod" => "src_tab_ok"})
      assert html(trace) =~ ~r/<button[^>]*phx-click="open_source"[^>]*phx-value-mod="src_tab_ok"/
      # asked once per module
      assert trace.assigns.source_known == %{src_tab_none: false, src_tab_ok: true}

      profile = %{page(ProfileLive, node, modules) | view: ProfileLive}
      profile = Phoenix.Component.assign(profile, available: true)
      profile = event(profile, "pick_module", %{"mod" => "src_tab_none"})
      refute html(profile) =~ ~s(phx-click="open_source")
    end

    test "the Profile tab has the same Source button and tabs", %{node: node} do
      load(node, :src_tab_p)
      socket = %{page(ProfileLive, node, [{:src_tab_p, [hello: 1], []}]) | view: ProfileLive}
      socket = Phoenix.Component.assign(socket, available: true)
      socket = event(socket, "pick_module", %{"mod" => "src_tab_p"})

      assert html(socket) =~ ~r/<button[^>]*phx-click="open_source"[^>]*phx-value-mod="src_tab_p"/

      socket = event(socket, "open_source", %{"mod" => "src_tab_p"})
      h = html(socket)
      assert h =~ ~r/phx-value-tab="main"[^>]*>\s*Profiling/
      assert h =~ "hello(Name)"
    end

    test "the Highlight.js language: Elixir for .ex/.exs, Erlang for .erl and rebuilt source" do
      assert SourceTabs.language(%{kind: :file, path: "/src/lib/my_app/worker.ex"}) == "elixir"
      assert SourceTabs.language(%{kind: :file, path: "/src/test/x_test.exs"}) == "elixir"
      assert SourceTabs.language(%{kind: :file, path: "/src/my_app/src/worker.erl"}) == "erlang"
      assert SourceTabs.language(%{kind: :file, path: "/src/include/x.hrl"}) == "erlang"
      assert SourceTabs.language(%{kind: :file, path: "/src/x.lfe"}) == "plaintext"
      # rebuilt from debug info is always Erlang, an Elixir module's too
      assert SourceTabs.language(%{kind: :debug_info, path: "/src/lib/x.ex"}) == "erlang"
      assert SourceTabs.language(%{kind: :none, path: nil}) == "plaintext"
    end

    test "Highlight.js is vendored and loaded before app.js, with Erlang and Elixir" do
      html =
        Phoenix.LiveViewTest.rendered_to_string(BeamdashWeb.Layouts.root(%{inner_content: ""}))

      scripts =
        Regex.scan(~r/<script defer src="([^"]+)"/, html, capture: :all_but_first)
        |> List.flatten()

      hl =
        ~w(highlight.min.js erlang.min.js elixir.min.js)
        |> Enum.map(&"/assets/vendor/highlight/#{&1}")

      assert Enum.take(scripts, -9) ==
               hl ++
                 [
                   "/assets/source_editor.js",
                   "/assets/console_completion.js",
                   "/assets/notebook_files.js",
                   "/assets/vendor/codemirror/editor.js",
                   "/assets/module_editor.js",
                   "/assets/app.js"
                 ]

      for path <- hl do
        file = Path.join(Application.app_dir(:beamdash, "priv/static"), path)
        assert File.read!(file) =~ "11.9.0", path
      end
    end

    test "the Processes tab: the selected process's module, and its source in a tab",
         %{node: node} do
      server = :erpc.call(node, :erlang, :whereis, [:code_server])

      socket = %Phoenix.LiveView.Socket{
        private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}},
        view: BeamdashWeb.HomeLive
      }

      {:ok, socket} = BeamdashWeb.HomeLive.mount(%{}, %{}, socket)
      socket = Phoenix.Component.assign(socket, syntax: :erlang, status: :connected, node: node)

      socket = event(socket, "select", %{"pid" => Beamdash.Format.pid(server, :erlang)})
      {:noreply, socket} = BeamdashWeb.HomeLive.handle_info({:detail_tick, server}, socket)
      assert %{module: :code_server, application: :kernel} = socket.assigns.module_info

      # the Source button opens only that module
      assert event(socket, "open_source", %{"mod" => "lists"}).assigns.sources == []
      socket = event(socket, "open_source", %{"mod" => "code_server"})
      assert socket.assigns.source_tab == :code_server

      h = html(socket)
      assert h =~ ~r/phx-value-tab="main"[^>]*>\s*Processes/
      assert h =~ ~s(class="src-panel")
      # the page itself is hidden, not removed
      assert h =~ ~r/<div hidden[^>]*>/

      # closing the process's panel keeps the source tab
      socket = event(socket, "close_details", %{})
      assert socket.assigns.module_info == nil
      assert [%{mod: :code_server}] = socket.assigns.sources
    end

    test "the Processes tab opens ?pid= from before a reconnect instead of crashing",
         %{node: node} do
      server = :erpc.call(node, :erlang, :whereis, [:code_server])

      [_, id, serial] =
        Regex.run(~r/^<\d+\.(\d+)\.(\d+)>$/, inspect(server) |> String.trim_leading("#PID"))

      socket = %Phoenix.LiveView.Socket{
        private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}},
        view: BeamdashWeb.HomeLive
      }

      {:ok, socket} = BeamdashWeb.HomeLive.mount(%{}, %{}, socket)
      socket = Phoenix.Component.assign(socket, syntax: :erlang, status: :connected, node: node)
      # ?pid= is only followed once connected
      socket = %{socket | transport_pid: self()}

      {:noreply, socket} =
        BeamdashWeb.HomeLive.handle_params(%{"pid" => "<99999.#{id}.#{serial}>"}, "", socket)

      assert socket.assigns.selected == server
    end

    test "a new node closes the sources" do
      socket = SourceTabs.init(%Phoenix.LiveView.Socket{})
      socket = Phoenix.Component.assign(socket, sources: [%{mod: :x}], source_tab: :x)

      {:noreply, socket} =
        TraceLive.handle_info({:beamdash_target, {:disconnected, :closed}}, %{
          socket
          | view: TraceLive
        })

      assert socket.assigns.sources == []
    end
  end

  test "Modules selection loads source into the editor", %{node: node} do
    path = load(node, :src_editor_demo)

    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = BeamdashWeb.ModulesLive.mount(%{}, %{}, socket)

    {:noreply, selected} =
      BeamdashWeb.ModulesLive.handle_event("select", %{"module" => "src_editor_demo"}, socket)

    assert selected.assigns.source == File.read!(path)
    assert {"hello", 1} in selected.assigns.exported_functions

    assert {:reply, %{items: items}, _} =
             BeamdashWeb.ModulesLive.handle_event(
               "complete_editor",
               %{"token" => "src_editor_demo:he", "language" => "erlang"},
               selected
             )

    assert Enum.any?(
             items,
             &(&1.label == "src_editor_demo:hello/1" and &1.insert == "src_editor_demo:hello(")
           )

    html =
      selected.assigns
      |> Map.put(:syntax, :erlang)
      |> BeamdashWeb.ModulesLive.render()
      |> Phoenix.LiveViewTest.rendered_to_string()

    assert html =~ "a comment only the source file has"
    assert html =~ ~s(list="running-module-functions")
    assert html =~ ~s(label="hello/1")
  end

  test "Modules opens the module named in the URL without creating atoms", %{node: node} do
    path = load(node, :src_editor_link)

    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = BeamdashWeb.ModulesLive.mount(%{}, %{}, socket)

    {:noreply, selected} =
      BeamdashWeb.ModulesLive.handle_params(%{"module" => "src_editor_link"}, "", socket)

    assert selected.assigns.selected == :src_editor_link
    assert selected.assigns.source == File.read!(path)

    unknown = "not_loaded_#{System.unique_integer([:positive])}"

    {:noreply, unchanged} =
      BeamdashWeb.ModulesLive.handle_params(%{"module" => unknown}, "", socket)

    assert unchanged.assigns.selected == nil
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "Modules selection explains when source is unavailable", %{node: node} do
    path = load(node, :src_editor_missing, [])
    File.rm!(path)

    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = BeamdashWeb.ModulesLive.mount(%{}, %{}, socket)

    {:noreply, selected} =
      BeamdashWeb.ModulesLive.handle_event("select", %{"module" => "src_editor_missing"}, socket)

    assert selected.assigns.message =~ "compiled without debug info"
  end

  test "Modules selection tries all Module Source settings when the owner path misses", %{
    node: node
  } do
    mod = :src_editor_cross
    path = load(node, mod, [])
    text = File.read!(path)
    File.rm!(path)
    dir = Path.join(Path.dirname(path), "checkout")
    local = Path.join(dir, "src/#{mod}.erl")
    File.mkdir_p!(Path.dirname(local))
    File.write!(local, text)

    {:ok, :ok} =
      Target.rpc(node, :application, :load, [
        {:application, :src_editor_owner, [vsn: ~c"1", modules: [mod]]}
      ])

    assert {:ok, {:ok, :src_editor_owner}} =
             Target.rpc(node, :application, :get_application, [mod])

    Beamdash.Settings.put_source_dir("src_editor_owner", Path.join(dir, "missing"))
    Beamdash.Settings.put_source_dir("src_editor_checkout", dir)

    on_exit(fn ->
      Beamdash.Settings.delete_source_dir("src_editor_owner")
      Beamdash.Settings.delete_source_dir("src_editor_checkout")
    end)

    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = BeamdashWeb.ModulesLive.mount(%{}, %{}, socket)

    {:noreply, selected} =
      BeamdashWeb.ModulesLive.handle_event("select", %{"module" => Atom.to_string(mod)}, socket)

    assert selected.assigns.source == text
    assert selected.assigns.message =~ local
  end

  test "Modules and SourceTabs load the same local source for an Elixir module", %{node: node} do
    mod = PaceKeeperCore.Vnode
    dir = Path.join(System.tmp_dir!(), "beamdash-vnode-#{System.unique_integer([:positive])}")
    path = Path.join(dir, "lib/pace_keeper_core/vnode.ex")
    File.mkdir_p!(Path.dirname(path))
    File.write!(Path.join(dir, "mix.exs"), "# local project")
    text = "defmodule PaceKeeperCore.Vnode do\n  def value, do: :ok\nend\n"
    File.write!(path, text)

    forms = [
      {:attribute, 1, :module, mod},
      {:attribute, 2, :export, [value: 0]},
      {:function, 3, :value, 0, [{:clause, 3, [], [], [{:atom, 3, :ok}]}]}
    ]

    {:ok, ^mod, beam} =
      :compile.forms(forms, [:binary, {:source, ~c"/release/lib/pace_keeper_core/vnode.ex"}])

    {:ok, {:module, ^mod}} = Target.rpc(node, :code, :load_binary, [mod, ~c"vnode.beam", beam])
    Beamdash.Settings.put_source_dir("pace_keeper", dir)

    on_exit(fn ->
      Beamdash.Settings.delete_source_dir("pace_keeper")
      File.rm_rf!(dir)
    end)

    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = BeamdashWeb.ModulesLive.mount(%{}, %{}, socket)

    source_tab =
      SourceTabs.event("open_source", %{"mod" => Atom.to_string(mod)}, SourceTabs.init(socket), [
        mod
      ])

    assert [%{source: %{kind: :local, text: ^text}}] = source_tab.assigns.sources

    panel =
      Phoenix.LiveViewTest.render_component(&SourceTabs.panel/1,
        sources: source_tab.assigns.sources,
        current: mod,
        syntax: :elixir
      )

    assert panel =~ ~s(href="/modules?module=Elixir.PaceKeeperCore.Vnode")

    {:noreply, selected} =
      BeamdashWeb.ModulesLive.handle_event("select", %{"module" => Atom.to_string(mod)}, socket)

    assert selected.assigns.source == text
    assert selected.assigns.language == "elixir"
    assert selected.assigns.project == dir
    assert selected.assigns.original == %{source: text, language: "elixir", project: dir}
    assert selected.assigns.message =~ path

    {:noreply, linked} =
      BeamdashWeb.ModulesLive.handle_params(%{"module" => Atom.to_string(mod)}, "", socket)

    assert linked.assigns.selected == mod
    assert linked.assigns.source == text

    html =
      selected.assigns
      |> Map.put(:syntax, :elixir)
      |> BeamdashWeb.ModulesLive.render()
      |> Phoenix.LiveViewTest.rendered_to_string()

    assert html =~ ~s(phx-hook="CodeMirrorEditor")
    assert html =~ ~s(data-language="elixir")
    assert html =~ ~s(id="module-source-Elixir.PaceKeeperCore.Vnode")
    assert html =~ "defmodule PaceKeeperCore.Vnode"
  end
end
