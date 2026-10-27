defmodule Beamdash.PluginsUiTest do
  # The plugins UI: the Settings card, PluginLive, the stylesheet route and
  # the connection hook's list of active plugins. Each test runs a named
  # Beamdash.Plugins on its own plugins dir.
  #
  # As in logs_live_test.exs, the pages' callbacks are called directly on a
  # socket (Phoenix.LiveViewTest's live/2 needs lazy_html). A nested
  # LiveView renders as its static container only, so the plugin page is
  # mounted on its own with the session PluginLive gives it.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_private: 3, get_resp_header: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1, render_component: 2]
  import Beamdash.Test.PluginFixture, only: [copy_fixture: 2, start_app: 2, stop_app: 1]

  alias Beamdash.{Plugins, Target}
  alias Beamdash.Plugins.{Build, Spec}
  alias Beamdash.Test.Fixture
  alias BeamdashWeb.{Connection, PluginLive, PluginsSettings, SettingsLive}
  alias Phoenix.LiveView.{Lifecycle, Renderer, Socket}

  @endpoint BeamdashWeb.Endpoint
  @moduletag :capture_log

  @hello [HelloPlugin, HelloPlugin.HelloLive]
  # compiled and loaded at runtime
  @compile {:no_warn_undefined, @hello}

  setup do
    base =
      Path.join(System.tmp_dir!(), "beamdash_plugins_ui_#{System.unique_integer([:positive])}")

    dir = Path.join(base, "plugins")
    File.mkdir_p!(dir)
    old = Application.fetch_env(:beamdash, :plugins_dir)
    Application.put_env(:beamdash, :plugins_dir, dir)

    on_exit(fn ->
      Build.unload(@hello)

      case old do
        {:ok, v} -> Application.put_env(:beamdash, :plugins_dir, v)
        :error -> Application.delete_env(:beamdash, :plugins_dir)
      end

      File.rm_rf(base)
    end)

    id = System.unique_integer([:positive])
    target = start_supervised!({Target, name: :"ui_target_#{id}"}, id: :target)

    server =
      start_supervised!(
        {Plugins, name: :"ui_plugins_#{id}", dir: dir, target: target, refresh_ms: 100},
        id: :plugins
      )

    src = copy_fixture(base, "hello")
    %{base: base, dir: dir, target: target, server: server, src: src}
  end

  defp path_spec(src), do: ~s|{:hello_plugin, path: "#{src}"}|

  defp install!(server, text) do
    {:ok, ref} = Plugins.install(server, text)
    assert_receive {:beamdash_plugins, {:installed, ^ref, _app}}, 30_000
  end

  defp socket(view) do
    %Socket{
      id: "phx-test",
      endpoint: @endpoint,
      router: BeamdashWeb.Router,
      view: view,
      transport_pid: self(),
      host_uri: URI.parse("http://localhost:4000"),
      private: %{lifecycle: %Lifecycle{}, live_temp: %{}, root_view: view}
    }
    |> Phoenix.Component.assign(:syntax, :erlang)
  end

  defp render(socket), do: socket |> Renderer.to_rendered(socket.view) |> rendered_to_string()

  defp event(socket, name, params) do
    {:noreply, socket} = socket.view.handle_event(name, params, socket)
    socket
  end

  defp info(socket, message) do
    {:noreply, socket} = socket.view.handle_info(message, socket)
    socket
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  # Feeds the install messages to the page until the install ends; returns
  # the page and the steps it showed.
  defp follow_install(socket, steps \\ []) do
    receive do
      {:beamdash_plugins, {:install, _ref, step}} = msg ->
        socket = info(socket, msg)
        follow_install(socket, steps ++ [{step, render(socket)}])

      {:beamdash_plugins, {done, _ref, _}} = msg when done in [:installed, :install_failed] ->
        {info(socket, msg), steps}
    after
      30_000 -> flunk("the install did not end")
    end
  end

  defp eventually(fun, tries \\ 100) do
    if fun.() or tries == 0 do
      assert fun.()
    else
      Process.sleep(50)
      eventually(fun, tries - 1)
    end
  end

  defp status(server),
    do: Enum.find(Plugins.list(server), &(&1.app == :hello_plugin)).status

  # a peer running hello_app at `vsn`, attached to `target`
  defp attach(ctx, vsn) do
    {peer, node} = Fixture.start_peer()
    on_exit(fn -> Fixture.stop_peer(peer) end)
    {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie(), ctx.target)
    if vsn, do: start_app(node, vsn)
    node
  end

  describe "Settings → Plugins" do
    defp settings(ctx) do
      {:ok, socket} =
        SettingsLive.mount(%{}, %{"plugins_server" => ctx.server}, socket(SettingsLive))

      socket
    end

    test "the card: the add form, examples, warning and the plugins dir", ctx do
      html = ctx |> settings() |> render()
      assert html =~ ~s(id="plugin-add-form")
      assert html =~ ~s(name="spec")
      assert html =~ escape(~s|{:riak_core_plugin, "~> 0.1"}|)
      assert html =~ escape(~s|{:riak_core_plugin, "0.0.1"}|)

      assert html =~
               escape(
                 ~s|{:riak_core_plugin, git: "https://github.com/dskliarov/beamdash-riak-core-plugin", tag: "0.0.1"}|
               )

      assert html =~
               escape(
                 ~s|{:riak_core_plugin, path: "~/projects/elixir/beamdash-riak-core-plugin"}|
               )

      assert html =~
               "A plugin runs inside beamdash with full access to the nodes you connect to, " <>
                 "and compiling it runs its code inside beamdash. Add only plugins you trust."

      assert html =~ ctx.dir
      assert html =~ "No plugins installed"
    end

    test "adding shows each step, then Installed and the row", ctx do
      socket = settings(ctx) |> event("plugin_add", %{"spec" => path_spec(ctx.src)})
      assert render(socket) =~ "Checking…"

      {socket, steps} = follow_install(socket)
      assert Enum.map(steps, &elem(&1, 0)) == [:checking, :fetching, :compiling, :loading]
      assert elem(List.keyfind(steps, :fetching, 0), 1) =~ "Fetching…"
      assert elem(List.keyfind(steps, :compiling, 0), 1) =~ "Compiling…"
      assert elem(List.keyfind(steps, :loading, 0), 1) =~ "Loading…"

      html = render(socket)
      assert html =~ "Installed Hello"
      assert html =~ ~s(id="plugin-hello_plugin")
      assert html =~ "hello_app ~&gt; 1.0"
      assert html =~ "waiting for hello_app"
      assert html =~ ~s(class="plugin-badge plugin-badge-path")
      assert html =~ ctx.src
      refute html =~ "No plugins installed"
    end

    test "a bad spec shows the Spec error", ctx do
      text = ~s|{:hello_plugin, "~> 1.0", only: :dev}|
      {:error, msg} = Spec.parse(text)

      {socket, _} = settings(ctx) |> event("plugin_add", %{"spec" => text}) |> follow_install()
      html = render(socket)
      assert html =~ ~r/<pre[^>]*>\s*#{Regex.escape(escape(msg))}/
      refute html =~ "Installed"
      # the text stays in the field, to fix it
      assert socket.assigns.plugin_spec == text
    end

    test "remove asks first; a path plugin's folder is not touched", ctx do
      install!(ctx.server, path_spec(ctx.src))
      socket = settings(ctx)
      html = render(socket)
      assert html =~ ~s(phx-click="plugin_remove")
      refute html =~ "Confirm remove"

      socket = event(socket, "plugin_remove", %{"app" => "hello_plugin"})
      html = render(socket)
      assert html =~ "Confirm remove"
      assert html =~ "Cancel"
      assert html =~ "is not touched"
      assert html =~ ctx.src

      socket = event(socket, "plugin_remove_cancel", %{})
      refute render(socket) =~ "Confirm remove"

      socket =
        socket
        |> event("plugin_remove", %{"app" => "hello_plugin"})
        |> event("plugin_remove_confirm", %{"app" => "hello_plugin"})

      assert Plugins.list(ctx.server) == []
      assert File.dir?(ctx.src)
      html = render(socket)
      assert html =~ "Removed hello_plugin"
      refute html =~ ~s(id="plugin-hello_plugin")
    end

    test "Rebuild recompiles a path plugin", ctx do
      install!(ctx.server, path_spec(ctx.src))
      socket = settings(ctx)
      assert render(socket) =~ ~s(phx-click="plugin_rebuild")

      socket = event(socket, "plugin_rebuild", %{"app" => "hello_plugin"})
      assert render(socket) =~ "Rebuilding…"
      assert_receive {ref, _} = msg when is_reference(ref), 30_000
      socket = info(socket, msg)
      assert render(socket) =~ "Rebuilt Hello"
    end

    test "a failed rebuild shows its error; a crashed one says so", ctx do
      install!(ctx.server, path_spec(ctx.src))

      File.write!(
        Path.join(ctx.src, "lib/hello_plugin/broken.ex"),
        "defmodule HelloPlugin.Broken do\n"
      )

      socket = settings(ctx) |> event("plugin_rebuild", %{"app" => "hello_plugin"})
      assert_receive {ref, {:error, msg}} = reply when is_reference(ref), 30_000
      html = socket |> info(reply) |> render()
      assert html =~ ~r/<pre class="plugin-output error"[^>]*>/
      assert html =~ escape(msg) |> String.slice(0, 40)
      refute html =~ "Rebuilding…"

      ref = make_ref()

      socket =
        Phoenix.Component.assign(socket, :plugin_rebuilding, %{ref => "hello_plugin"})
        |> info({:DOWN, ref, :process, self(), :killed})

      html = render(socket)
      assert html =~ "the rebuild crashed: :killed"
      assert socket.assigns.plugin_rebuilding == %{}
      Build.unload([HelloPlugin.Broken])
    end

    test "a refused remove shows why; a second confirm does nothing", ctx do
      socket =
        settings(ctx)
        |> event("plugin_remove", %{"app" => "nope"})
        |> event("plugin_remove_confirm", %{"app" => "nope"})

      assert render(socket) =~ "nope is not installed"

      install!(ctx.server, path_spec(ctx.src))

      socket =
        socket
        |> SettingsLive.plugins_changed(:changed)
        |> event("plugin_remove", %{"app" => "hello_plugin"})
        |> event("plugin_remove_confirm", %{"app" => "hello_plugin"})
        |> event("plugin_remove_confirm", %{"app" => "hello_plugin"})

      assert socket.assigns.plugin_notice == {:ok, "Removed hello_plugin"}
      # nor without asking first
      install!(ctx.server, path_spec(ctx.src))
      event(socket, "plugin_remove_confirm", %{"app" => "hello_plugin"})
      assert [_] = Plugins.list(ctx.server)
    end

    test "messages of another install are ignored; a second Add keeps the first", ctx do
      socket = settings(ctx) |> event("plugin_add", %{"spec" => path_spec(ctx.src)})
      install = socket.assigns.plugin_install
      other = make_ref()

      socket =
        socket
        |> info({:beamdash_plugins, {:install, other, :loading}})
        |> info({:beamdash_plugins, {:install_failed, other, "not mine"}})
        |> info({:beamdash_plugins, {:installed, other, :x}})

      assert socket.assigns.plugin_install == install

      socket = event(socket, "plugin_add", %{"spec" => ~s|{:other_plugin, path: "/x"}|})
      assert socket.assigns.plugin_install == install
      assert socket.assigns.plugin_spec == path_spec(ctx.src)

      {socket, _} = follow_install(socket)
      assert render(socket) =~ "Installed Hello"
    end

    test "a registry that doesn't answer never breaks the page", ctx do
      {:ok, socket} =
        SettingsLive.mount(%{}, %{"plugins_server" => :ui_no_such_server}, socket(SettingsLive))

      assert render(socket) =~ "No plugins installed"
      socket = event(socket, "plugin_add", %{"spec" => path_spec(ctx.src)})
      assert render(socket) =~ "the plugin registry is not answering"

      socket =
        socket
        |> event("plugin_remove", %{"app" => "hello_plugin"})
        |> event("plugin_remove_confirm", %{"app" => "hello_plugin"})

      assert {:error, "hello_plugin is not removed: the plugin registry" <> _} =
               socket.assigns.plugin_notice
    end

    test "the list follows changes made elsewhere", ctx do
      socket = settings(ctx)
      install!(ctx.server, path_spec(ctx.src))
      refute render(socket) =~ ~s(id="plugin-hello_plugin")
      socket = SettingsLive.plugins_changed(socket, :changed)
      assert render(socket) =~ ~s(id="plugin-hello_plugin")

      :ok = Plugins.remove(ctx.server, "hello_plugin")
      socket = SettingsLive.plugins_changed(socket, {:removed, :hello_plugin})
      refute render(socket) =~ ~s(id="plugin-hello_plugin")
    end

    test "rows: source, resolved, status texts; Rebuild only for path plugins" do
      base = %{
        app: :hello_plugin,
        spec_text: ~s|{:hello_plugin, "~> 0.1"}|,
        supports: [{:hello_app, "~> 1.0"}, {:other_app, nil}],
        plugin: %{name: "Hello", pages: []},
        modules: [],
        build_error: nil
      }

      plugins = [
        %{base | app: :a_hex} |> Map.merge(%{source: :hex, resolved: "0.1.2", status: :active}),
        %{base | app: :b_git}
        |> Map.merge(%{
          source: :git,
          resolved: "0123456789abcdef0123456789abcdef01234567",
          status: {:incompatible, :hello_app, "2.0.0", "~> 1.0"}
        }),
        %{base | app: :c_path, plugin: nil}
        |> Map.merge(%{source: :path, resolved: "/x/y", status: {:failed, "boom <here>"}}),
        %{base | app: :d_path, build_error: "syntax error"}
        |> Map.merge(%{source: :path, resolved: "/x/z", status: :waiting})
      ]

      html =
        render_component(&PluginsSettings.card/1,
          plugins: plugins,
          dir: "/plugins",
          install: nil,
          spec: "",
          confirm_remove: nil,
          rebuilding: %{},
          notes: %{}
        )

      row = fn app ->
        [row] = Regex.run(~r/<li[^>]*id="plugin-#{app}".*?<\/li>/s, html)
        row
      end

      assert row.("a_hex") =~ ~s(plugin-badge-hex)
      assert row.("a_hex") =~ "0.1.2"
      assert row.("a_hex") =~ ~r/>\s*active\s*</
      assert row.("a_hex") =~ "hello_app ~&gt; 1.0"
      assert row.("a_hex") =~ "other_app"
      refute row.("a_hex") =~ "plugin_rebuild"

      assert row.("b_git") =~ ~s(plugin-badge-git)
      assert row.("b_git") =~ ">0123456<"
      assert row.("b_git") =~ "hello_app 2.0.0 running, needs ~&gt; 1.0"
      refute row.("b_git") =~ "plugin_rebuild"

      assert row.("c_path") =~ "failed: boom &lt;here&gt;"
      assert row.("c_path") =~ ~s(phx-click="plugin_rebuild")
      # no name without a loaded plugin: the app instead
      assert row.("c_path") =~ ~r/<strong[^>]*>\s*c_path\s*</

      assert row.("d_path") =~ "waiting for hello_app or other_app"
      assert row.("d_path") =~ "syntax error"
    end
  end

  describe "PluginLive" do
    defp plugin_live(ctx, app \\ "hello_plugin", slug \\ "hello") do
      session = %{"plugins_server" => ctx.server, "target" => ctx.target}

      {:ok, socket} =
        PluginLive.mount(%{"plugin" => app, "page" => slug}, session, socket(PluginLive))

      socket
    end

    test "an unknown plugin or page", ctx do
      for {app, slug} <- [{"nope", "hello"}, {"..", "x"}] do
        html = ctx |> plugin_live(app, slug) |> render()
        assert html =~ "No such plugin page"
        assert html =~ ~s(href="/settings")
        # beamdash's header
        assert html =~ ~s(id="main-nav")
      end

      install!(ctx.server, path_spec(ctx.src))
      assert ctx |> plugin_live("hello_plugin", "nope") |> render() =~ "No such plugin page"
    end

    test "the route renders through the live_session hooks" do
      html = build_conn() |> get("/plugins/nope/hello") |> html_response(200)
      assert html =~ "No such plugin page"
      assert html =~ ~s(id="connect-form")
    end

    test "incompatible with a running version that isn't valid says so", ctx do
      install!(ctx.server, path_spec(ctx.src))
      socket = plugin_live(ctx)

      attach(ctx, "weird")
      eventually(fn -> match?({:incompatible, _, _, _}, status(ctx.server)) end)
      socket = PluginLive.plugins_changed(socket, :changed)

      assert render(socket) =~
               "hello_app weird is running, which isn&#39;t a valid version; " <>
                 "this plugin supports ~&gt; 1.0"
    end

    test "waiting, then incompatible, then active, then removed", ctx do
      install!(ctx.server, path_spec(ctx.src))
      socket = plugin_live(ctx)
      html = render(socket)
      assert html =~ "Hello needs hello_app (~&gt; 1.0) running on the attached node"
      refute html =~ ~s(id="plugin-hello_plugin-hello")

      node = attach(ctx, "2.0.0")
      eventually(fn -> match?({:incompatible, _, _, _}, status(ctx.server)) end)
      socket = PluginLive.plugins_changed(socket, :changed)
      assert render(socket) =~ "hello_app 2.0.0 is running; this plugin supports ~&gt; 1.0"

      stop_app(node)
      start_app(node, "1.2.0")
      eventually(fn -> status(ctx.server) == :active end)
      socket = PluginLive.plugins_changed(socket, :changed)
      html = render(socket)
      assert html =~ ~r/<div[^>]* id="plugin-hello_plugin-hello"/
      assert html =~ ~s(data-phx-session=)
      assert html =~ ~s(<link rel="stylesheet" href="/plugins/hello_plugin/plugin.css">)
      # the plugin's page is marked in the menu the connection hook fills
      conn = %{status: :disconnected, node: nil, info: nil, node_input: "", error: nil}
      conn = Map.put(conn, :plugins, Plugins.active(ctx.server))
      html = socket |> Phoenix.Component.assign(:conn, conn) |> render()
      assert html =~ ~r/<summary[^>]*class="[^"]*active/

      # on the static render the plugin page isn't run, a placeholder holds its place
      html = %{socket | transport_pid: nil} |> render()
      refute html =~ ~s(data-phx-session=)
      assert html =~ ~s(id="plugin-hello_plugin-hello-loading")

      Plugins.remove(ctx.server, "hello_plugin")
      socket = PluginLive.plugins_changed(socket, {:removed, :hello_plugin})
      html = render(socket)
      assert html =~ "Plugin removed"
      refute html =~ ~s(id="plugin-hello_plugin-hello")
      # still removed while it isn't back
      socket = PluginLive.plugins_changed(socket, :changed)
      assert render(socket) =~ "Plugin removed"

      # installed again while the page is open
      Build.unload(@hello)
      install!(ctx.server, path_spec(ctx.src))
      eventually(fn -> status(ctx.server) == :active end)
      socket = PluginLive.plugins_changed(socket, :changed)
      html = render(socket)
      refute html =~ "Plugin removed"
      assert html =~ ~r/<div[^>]* id="plugin-hello_plugin-hello"/
    end

    test "a new syntax mounts the plugin page again", ctx do
      install!(ctx.server, path_spec(ctx.src))
      attach(ctx, "1.2.0")
      eventually(fn -> status(ctx.server) == :active end)
      socket = plugin_live(ctx)
      assert socket.assigns.page_session["syntax"] == :erlang

      socket =
        socket |> Phoenix.Component.assign(:syntax, :elixir) |> PluginLive.syntax_changed()

      assert socket.assigns.page_session["syntax"] == :elixir
      refute render(socket) =~ ~s(data-phx-session=)
      assert_receive :beamdash_plugin_remount
      socket = info(socket, :beamdash_plugin_remount)
      assert render(socket) =~ ~r/<div[^>]* id="plugin-hello_plugin-hello"[^>]*data-phx-session=/
    end

    test "a plugin page that raises doesn't break beamdash's static render", ctx do
      live = Path.join(ctx.src, "lib/hello_plugin/hello_live.ex")

      File.write!(
        live,
        String.replace(
          File.read!(live),
          "{:ok, socket |> assign(count: 0) |> load()}",
          ~s|raise "boom in the plugin"|
        )
      )

      install!(ctx.server, path_spec(ctx.src))
      attach(ctx, "1.2.0")
      eventually(fn -> status(ctx.server) == :active end)

      html =
        build_conn()
        |> Plug.Test.init_test_session(%{"plugins_server" => ctx.server, "target" => ctx.target})
        |> get("/plugins/hello_plugin/hello")
        |> html_response(200)

      assert html =~ ~s(id="main-nav")
      assert html =~ "Loading Hello…"
      refute html =~ "boom in the plugin"
    end

    test "while the plugin is built at startup", ctx do
      File.write!(Path.join(ctx.src, "lib/hello_plugin/slow.ex"), """
      defmodule HelloPlugin.Slow do
        Process.sleep(1_500)
        def y, do: 2
      end
      """)

      dir = Path.join(ctx.base, "plugins2")
      File.mkdir_p!(dir)
      Application.put_env(:beamdash, :plugins_dir, dir)

      File.write!(
        Path.join(dir, "plugins.json"),
        Jason.encode!([
          %{
            "app" => "hello_plugin",
            "spec" => path_spec(ctx.src),
            "source" => "path",
            "resolved" => ctx.src,
            "supports" => [%{"app" => "hello_app", "requirement" => "~> 1.0"}]
          }
        ])
      )

      server =
        start_supervised!(
          {Plugins,
           name: :"ui_plugins_b_#{System.unique_integer([:positive])}",
           dir: dir,
           target: ctx.target},
          id: :plugins_b
        )

      eventually(fn -> status(server) == :building end)
      html = ctx |> Map.put(:server, server) |> plugin_live() |> render()
      assert html =~ "hello_plugin is still being built"
      # let the build end before the dir goes
      eventually(fn -> status(server) != :building end)
      Build.unload([HelloPlugin.Slow])
    end

    test "the plugin page mounts with the session PluginLive gives it", ctx do
      install!(ctx.server, path_spec(ctx.src))
      node = attach(ctx, "1.2.0")
      eventually(fn -> status(ctx.server) == :active end)

      socket = plugin_live(ctx)

      assert %{
               "plugin_app" => :hello_plugin,
               "plugin_module" => HelloPlugin,
               "syntax" => :erlang,
               "target" => target
             } = socket.assigns.page_session

      assert target == ctx.target

      {:ok, page} =
        HelloPlugin.HelloLive.mount(
          :not_mounted_at_router,
          socket.assigns.page_session,
          socket(HelloPlugin.HelloLive)
        )

      assert page.assigns.plugin.name == "Hello"

      html = page.assigns |> HelloPlugin.HelloLive.render() |> rendered_to_string()
      assert html =~ "Hello from #{node}"

      assert html =~
               ~r/id="hello-plugin-rpc">\s*\{ok,\s*(&#39;)?#{Regex.escape(Atom.to_string(node))}/
    end
  end

  describe "stylesheet route" do
    test "serves an installed plugin's plugin.css, else 404", ctx do
      install!(ctx.server, path_spec(ctx.src))

      get_css = fn path ->
        build_conn() |> put_private(:beamdash_plugins_server, ctx.server) |> get(path)
      end

      conn = get_css.("/plugins/hello_plugin/plugin.css")
      assert conn.status == 200
      assert [type] = get_resp_header(conn, "content-type")
      assert type =~ "text/css"
      assert conn.resp_body == File.read!(Path.join(ctx.src, "priv/static/plugin.css"))
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

      assert get_css.("/plugins/nope/plugin.css").status == 404
      assert get_css.("/plugins/..%2F..%2Fetc/plugin.css").status == 404
      assert get_css.("/plugins/../../etc/passwd").status == 404

      # installed, but without a stylesheet
      File.rm!(Path.join(ctx.src, "priv/static/plugin.css"))
      assert get_css.("/plugins/hello_plugin/plugin.css").status == 404
    end

    test "a symlinked stylesheet is refused", ctx do
      install!(ctx.server, path_spec(ctx.src))
      css = Path.join(ctx.src, "priv/static/plugin.css")
      secret = Path.join(ctx.base, "secret.txt")
      File.write!(secret, "secret")

      File.rm!(css)
      File.ln_s!(secret, css)
      assert Plugins.css_path(ctx.server, "hello_plugin") == :error

      # a folder on the way
      static = Path.join(ctx.src, "priv/static")
      outside = Path.join(ctx.base, "outside")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "plugin.css"), "a {}")
      File.rm_rf!(static)
      File.ln_s!(outside, static)
      assert Plugins.css_path(ctx.server, "hello_plugin") == :error

      conn =
        build_conn()
        |> put_private(:beamdash_plugins_server, ctx.server)
        |> get("/plugins/hello_plugin/plugin.css")

      assert conn.status == 404
    end

    test "css_path and dir", ctx do
      assert Plugins.css_path(ctx.server, "hello_plugin") == :error
      install!(ctx.server, path_spec(ctx.src))

      assert Plugins.css_path(ctx.server, "hello_plugin") ==
               {:ok, Path.join(ctx.src, "priv/static/plugin.css")}

      assert Plugins.css_path(ctx.server, :hello_plugin) ==
               {:ok, Path.join(ctx.src, "priv/static/plugin.css")}

      assert Plugins.dir(ctx.server) == ctx.dir
    end
  end

  describe "connection hook" do
    test "keeps the active plugins and tells the page" do
      socket =
        %Socket{view: SettingsLive}
        |> Phoenix.Component.assign(:conn, %{status: :disconnected, plugins: [:stale]})
        |> Phoenix.Component.assign(:plugins, [])
        |> Phoenix.Component.assign(:plugins_server, Beamdash.Plugins)

      assert {:halt, socket} = Connection.handle_info({:beamdash_plugins, :changed}, socket)
      assert socket.assigns.conn.plugins == Plugins.active()

      # install progress is the page's own
      msg = {:beamdash_plugins, {:install, make_ref(), :fetching}}
      assert {:cont, _} = Connection.handle_info(msg, socket)
    end
  end
end
