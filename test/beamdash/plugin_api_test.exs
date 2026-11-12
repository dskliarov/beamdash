defmodule Beamdash.PluginApiTest do
  # The public plugin API (Beamdash.Plugin, Beamdash.Plugin.Page,
  # Beamdash.Plugin.Format) and the fixture plugin under
  # test/fixtures/plugins/hello_plugin, which is not compiled with beamdash:
  # it is compiled here into a tmp ebin, loaded, and purged afterwards.
  #
  # Pages are tested as logs_live_test.exs does: the LiveView callbacks are
  # called directly on a socket with a transport pid (no lazy_html).
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Beamdash.{Plugin, Target}
  alias Beamdash.Test.Fixture
  alias Phoenix.LiveView.{Lifecycle, Socket}

  @moduletag :capture_log

  # compiled and loaded at runtime, in setup_all
  @compile {:no_warn_undefined, [HelloPlugin, HelloPlugin.HelloLive, HelloPlugin.Tools]}

  @fixture Path.expand("../fixtures/plugins/hello_plugin", __DIR__)

  setup_all do
    tmp_ebin =
      Path.join(System.tmp_dir!(), "beamdash_plugin_api_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_ebin)
    files = Path.wildcard(@fixture <> "/lib/**/*.ex")

    {result, stderr} =
      with_io(:stderr, fn ->
        Kernel.ParallelCompiler.compile_to_path(files, tmp_ebin, return_diagnostics: true)
      end)

    {:ok, modules, %{compile_warnings: compile, runtime_warnings: runtime}} = result
    warnings = compile ++ runtime

    true = Code.prepend_path(tmp_ebin)
    Enum.each(modules, &Code.ensure_loaded!/1)

    on_exit(fn ->
      for mod <- [HelloPlugin, HelloPlugin.HelloLive, HelloPlugin.Tools] do
        :code.purge(mod)
        :code.delete(mod)
        :code.purge(mod)
      end

      Code.delete_path(tmp_ebin)
      File.rm_rf(tmp_ebin)
    end)

    %{modules: modules, warnings: warnings, stderr: stderr}
  end

  # Compiles `source` (which should define `mod`), purging `mod` afterwards.
  defp compile(source, mod) do
    Code.compile_string(source)
  after
    :code.purge(mod)
    :code.delete(mod)
    :code.purge(mod)
  end

  defp unique(prefix), do: Module.concat(prefix, "M#{System.unique_integer([:positive])}")

  defp plugin_source(mod, opts),
    do: "defmodule #{inspect(mod)} do\n  use Beamdash.Plugin, #{opts}\nend\n"

  defp start_connected_target do
    {peer, node} = Fixture.start_peer()
    on_exit(fn -> Fixture.stop_peer(peer) end)
    target = start_target()
    {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie(), target)
    {target, node}
  end

  defp start_target do
    id = System.unique_integer([:positive])
    start_supervised!({Target, name: :"plugin_api_target_#{id}"}, id: :"target_#{id}")
  end

  defp mount(page, session) do
    socket = %Socket{
      transport_pid: self(),
      private: %{lifecycle: %Lifecycle{}, live_temp: %{}}
    }

    {:ok, socket} = page.mount(%{}, session, socket)
    socket
  end

  defp render(page, socket),
    do: socket.assigns |> page.render() |> Phoenix.LiveViewTest.rendered_to_string()

  describe "the fixture plugin" do
    test "compiles without warnings", ctx do
      assert Enum.sort(ctx.modules) == [HelloPlugin, HelloPlugin.HelloLive, HelloPlugin.Tools]
      assert ctx.warnings == [], ctx.stderr
    end

    test "__beamdash_plugin__/0 is its declaration" do
      assert %{
               name: "Hello",
               pages: [%{slug: "hello", label: "Hello", module: HelloPlugin.HelloLive}],
               main: "hello",
               mcp_tools: [
                 %{
                   name: "greet",
                   description: "Greet someone by name",
                   input_schema: %{
                     type: "object",
                     properties: %{name: %{type: "string"}},
                     required: ["name"]
                   },
                   call: {HelloPlugin.Tools, :greet}
                 }
               ]
             } = HelloPlugin.__beamdash_plugin__()
    end

    test "the greet tool greets the name it is given" do
      assert {:ok, %{greeting: "Hello, Ada!"}} = HelloPlugin.Tools.greet(%{"name" => "Ada"})
    end

    test "the fixture is not part of beamdash's compile paths" do
      paths = Mix.Project.config()[:elixirc_paths]
      refute Enum.any?(paths, &String.starts_with?(&1, "test/fixtures"))
      refute Enum.any?(paths, &(&1 == "test"))
    end
  end

  describe "use Beamdash.Plugin options" do
    @pages ~s|pages: [{"ok", "OK", Some.Page}]|

    for {what, opts, message} <- [
          {"a missing :name", ~s|pages: [{"ok", "OK", Some.Page}]|, ~r/missing :name/},
          {"missing :pages", ~s|name: "x"|, ~r/missing :pages/},
          {"an unknown key", ~s|name: "x", #{@pages}, colour: :red|,
           ~r/unknown option :colour\. The supported options are :name, :pages, :main, :mcp_tools and :collectors$/},
          {"a main page that isn't one of the pages", ~s|name: "x", #{@pages}, main: "nope"|,
           ~r/:main must be the slug of one of the pages \("ok"\), got: "nope"/},
          {":apps", ~s|name: "x", #{@pages}, apps: [riak_core: "~> 1.0"]|,
           ~r/mix\.exs.*runtime: false/s},
          {":beamdash", ~s|name: "x", #{@pages}, beamdash: "~> 0.1"|,
           ~r/mix\.exs.*runtime: false/s},
          {":versions", ~s|name: "x", #{@pages}, versions: ["~> 1.0"]|,
           ~r/mix\.exs.*runtime: false/s},
          {"a bad slug", ~s|name: "x", pages: [{"Bad Slug", "Bad", Some.Page}]|,
           ~r/slug "Bad Slug"/},
          {"a slug starting with a digit", ~s|name: "x", pages: [{"1ring", "R", Some.Page}]|,
           ~r/slug "1ring"/},
          {"a slug with a trailing newline", ~s|name: "x", pages: [{"ring\\n", "R", P}]|,
           ~r/slug "ring\\n"/},
          {"a too long slug", ~s|name: "x", pages: [{"a#{String.duplicate("b", 32)}", "L", P}]|,
           ~r/slug/},
          {"a duplicate slug", ~s|name: "x", pages: [{"a", "A", P.A}, {"a", "B", P.B}]|,
           ~r/duplicate slug "a"/},
          {"a label that isn't a binary", ~s|name: "x", pages: [{"a", :label, P.A}]|, ~r/label/},
          {"a page module that isn't a module", ~s|name: "x", pages: [{"a", "A", "P.A"}]|,
           ~r/module/},
          {"a page that isn't a 3-tuple", ~s|name: "x", pages: [{"a", P.A}]|, ~r/pages/},
          {"an MCP tool name that isn't a slug",
           ~s|name: "x", #{@pages}, mcp_tools: [{"Bad Name", "T", %{}, {__MODULE__.Tools, :ring}}]|,
           ~r/invalid MCP tool name "Bad Name"/},
          {"an MCP tool whose schema isn't a map",
           ~s|name: "x", #{@pages}, mcp_tools: [{"t", "T", [], {__MODULE__.Tools, :ring}}]|,
           ~r/input schema of MCP tool "t" must be a map/},
          {"an MCP tool in another module",
           ~s|name: "x", #{@pages}, mcp_tools: [{"t", "T", %{}, {Other.Tools, :ring}}]|,
           ~r/nested under it/},
          {"two MCP tools with one name",
           ~s|name: "x", #{@pages}, mcp_tools: [{"t", "T", %{}, {__MODULE__.Tools, :a}}, {"t", "U", %{}, {__MODULE__.Tools, :b}}]|,
           ~r/duplicate MCP tool "t"/},
          {"a collector name that isn't a slug",
           ~s|name: "x", #{@pages}, collectors: [{"Bad", 5_000, {__MODULE__.C, :run}}]|,
           ~r/invalid collector name "Bad"/},
          {"a collector interval under a second",
           ~s|name: "x", #{@pages}, collectors: [{"c", 999, {__MODULE__.C, :run}}]|,
           ~r/interval of collector "c" must be an integer of at least 1000 ms/},
          {"a collector in another module",
           ~s|name: "x", #{@pages}, collectors: [{"c", 5_000, {Other.C, :run}}]|,
           ~r/nested under it/},
          {"two collectors with one name",
           ~s|name: "x", #{@pages}, collectors: [{"c", 5_000, {__MODULE__.C, :a}}, {"c", 6_000, {__MODULE__.C, :b}}]|,
           ~r/duplicate collector "c"/},
          {"a collector that isn't a 3-tuple",
           ~s|name: "x", #{@pages}, collectors: [{"c", {__MODULE__.C, :run}}]|,
           ~r/:collectors must be a list of \{name, interval_ms, \{module, fun\}\} tuples/}
        ] do
      # Source and options, not the regex: compiled regexes can't be escaped
      # on OTP 28 with Elixir < 1.19.
      @message {message.source, Regex.opts(message)}

      test "refuse #{what}" do
        mod = unique(BadPlugin)
        {source, opts} = @message

        error =
          assert_raise ArgumentError, Regex.compile!(source, opts), fn ->
            compile(plugin_source(mod, unquote(opts)), mod)
          end

        assert error.message =~ inspect(mod)
      end
    end

    test "page modules don't need to exist, and may be atoms or aliases" do
      mod = unique(GoodPlugin)

      source = """
      defmodule #{inspect(mod)} do
        alias Not.Compiled.Yet, as: Page
        use Beamdash.Plugin,
          name: "Good",
          pages: [{"one", "One", Page}, {"two-2_x", "Two", :some_erlang_page}, {"three", "Three", __MODULE__.Three}]
      end
      """

      try do
        Code.compile_string(source)

        assert mod.__beamdash_plugin__() == %{
                 name: "Good",
                 pages: [
                   %{slug: "one", label: "One", module: Not.Compiled.Yet},
                   %{slug: "two-2_x", label: "Two", module: :some_erlang_page},
                   %{slug: "three", label: "Three", module: Module.concat(mod, Three)}
                 ],
                 # the first page, as none is named
                 main: "one",
                 mcp_tools: [],
                 collectors: []
               }
      after
        :code.purge(mod)
        :code.delete(mod)
        :code.purge(mod)
      end
    end
  end

  test "mcp_tools are kept as declared, with their module and function" do
    mod = unique(ToolPlugin)

    source = """
    defmodule #{inspect(mod)} do
      use Beamdash.Plugin,
        name: "Tools",
        pages: [{"one", "One", __MODULE__.One}],
        mcp_tools: [{"ring", "The ring", %{type: "object", properties: %{}}, {__MODULE__.Tools, :ring}}]
    end
    """

    try do
      Code.compile_string(source)

      assert [
               %{
                 name: "ring",
                 description: "The ring",
                 input_schema: %{type: "object", properties: %{}},
                 call: {tools, :ring}
               }
             ] = mod.__beamdash_plugin__().mcp_tools

      assert tools == Module.concat(mod, Tools)
    after
      :code.purge(mod)
      :code.delete(mod)
      :code.purge(mod)
    end
  end

  test "collectors are kept as declared, with their interval, module and function" do
    mod = unique(CollectorPlugin)

    source = """
    defmodule #{inspect(mod)} do
      use Beamdash.Plugin,
        name: "Collectors",
        pages: [{"one", "One", __MODULE__.One}],
        collectors: [{"handoffs", 5_000, {__MODULE__.Collect, :handoffs}}]
    end
    """

    try do
      Code.compile_string(source)

      assert [%{name: "handoffs", interval: 5_000, call: {collect, :handoffs}}] =
               mod.__beamdash_plugin__().collectors

      assert collect == Module.concat(mod, Collect)
    after
      :code.purge(mod)
      :code.delete(mod)
      :code.purge(mod)
    end
  end

  describe "record and query" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "beamdash_plugin_store_#{System.unique_integer([:positive])}"
        )

      store = :"plugin_store_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Beamdash.Store,
         name: store, path: Path.join(dir, "e.sqlite3"), purge_interval: :infinity}
      )

      on_exit(fn -> File.rm_rf(dir) end)
      %{store: store}
    end

    test "rows come back newest first, kept apart by plugin and kind", %{store: store} do
      assert Plugin.history?(store: store)

      :ok =
        Plugin.record(
          :my_plugin,
          "handoffs",
          [
            %{at: 1_000, key: "c1", node: :a@h, data: %{module: :kv_vnode, partition: 0}},
            %{at: 2_000, key: "c2", data: %{pid: self()}}
          ],
          store: store
        )

      :ok = Plugin.record(:other_plugin, "handoffs", [%{data: 1}], store: store)

      assert {:ok, [second, first]} = Plugin.query(:my_plugin, "handoffs", store: store)

      assert first == %{
               id: first.id,
               at: 1_000,
               node: "a@h",
               key: "c1",
               data: %{"module" => "kv_vnode", "partition" => 0}
             }

      # no node attached: ""; a pid is stored as its text
      assert %{at: 2_000, node: "", key: "c2", data: %{"pid" => "#PID<" <> _}} = second

      assert {:ok, [%{key: "c1"}]} = Plugin.query(:my_plugin, "handoffs", key: "c1", store: store)

      assert {:ok, [%{at: 2_000}]} =
               Plugin.query(:my_plugin, "handoffs", from: 1_500, store: store)

      assert {:ok, [_]} = Plugin.query(:my_plugin, "handoffs", limit: 1, store: store)
      assert {:ok, [%{data: 1}]} = Plugin.query(:other_plugin, "handoffs", store: store)
    end

    test "at defaults to now", %{store: store} do
      before = System.system_time(:millisecond)
      :ok = Plugin.record(:my_plugin, "k", [%{data: %{}}], store: store)
      assert {:ok, [%{at: at}]} = Plugin.query(:my_plugin, "k", store: store)
      assert at >= before
    end

    test "a bad kind or row stores nothing", %{store: store} do
      big = String.duplicate("x", 70_000)

      for {kind, rows, message} <- [
            {"Bad Kind", [%{data: 1}], ~r/invalid kind "Bad Kind"/},
            {"k", [%{data: 1}, %{no: :data}], ~r/must be a map with :data/},
            {"k", [%{data: 1, at: "now"}], ~r/:at must be unix ms/},
            {"k", [%{data: 1, key: :c1}], ~r/:key must be a string/},
            {"k", [%{data: 1, node: 7}], ~r/:node must be a node or a string/},
            {"k", [%{data: big}], ~r/over 64 KB/}
          ] do
        assert {:error, msg} = Plugin.record(:my_plugin, kind, rows, store: store)
        assert msg =~ message
      end

      assert {:ok, []} = Plugin.query(:my_plugin, "k", store: store)
      assert {:error, "invalid kind" <> _} = Plugin.query(:my_plugin, "Nope", store: store)
    end

    test "with the event store off: disabled" do
      refute Plugin.history?(store: :no_such_store)
      assert Plugin.record(:p, "k", [%{data: 1}], store: :no_such_store) == {:error, :disabled}
      assert Plugin.query(:p, "k", store: :no_such_store) == {:error, :disabled}
    end
  end

  test "main_page/1: the page main names, else the first (older plugins have no main)" do
    pages = [%{slug: "a", label: "A", module: P.A}, %{slug: "b", label: "B", module: P.B}]
    assert Plugin.main_page(%{name: "x", pages: pages, main: "b"}).slug == "b"
    assert Plugin.main_page(%{name: "x", pages: pages}).slug == "a"
    assert Plugin.main_page(%{name: "x", pages: pages, main: "gone"}).slug == "a"
  end

  describe "rpc, app_running?, app_version" do
    test "rpc runs on the attached node" do
      {target, node} = start_connected_target()
      assert Plugin.rpc(:erlang, :node, [], 5_000, target: target) == {:ok, node}
      assert {:error, {:error, _}} = Plugin.rpc(:no_such_module, :f, [], 5_000, target: target)
    end

    test "rpc when disconnected" do
      target = start_target()
      assert Plugin.rpc(:erlang, :node, [], 5_000, target: target) == {:error, :not_connected}
    end

    test "rpc after a disconnect" do
      {target, _node} = start_connected_target()
      :ok = Target.disconnect(target)
      assert Plugin.rpc(:erlang, :node, [], 5_000, target: target) == {:error, :not_connected}
    end

    test "app_running? and app_version" do
      {target, node} = start_connected_target()
      {:ok, vsn} = :erpc.call(node, :application, :get_key, [:kernel, :vsn])

      assert Plugin.app_running?(:kernel, target)
      assert Plugin.app_version(:kernel, target) == {:ok, List.to_string(vsn)}
      refute Plugin.app_running?(:no_such_app, target)
      assert Plugin.app_version(:no_such_app, target) == :not_running
    end

    test "app_running? and app_version see library applications, as the registry does" do
      {target, node} = start_connected_target()
      # hello_app has no :mod, so no application master
      Beamdash.Test.PluginFixture.start_app(node, "1.2.0")

      assert Plugin.app_running?(:hello_app, target)
      assert Plugin.app_version(:hello_app, target) == {:ok, "1.2.0"}
    end

    test "a target that isn't running: not connected, not running" do
      assert Plugin.rpc(:erlang, :node, [], 1_000, target: :no_such_target) ==
               {:error, :not_connected}

      refute Plugin.app_running?(:x, :no_such_target)
      assert Plugin.app_version(:x, :no_such_target) == :not_running
    end

    test "app_running? and app_version when disconnected" do
      target = start_target()
      refute Plugin.app_running?(:kernel, target)
      assert Plugin.app_version(:kernel, target) == :not_running
    end

    test "version is beamdash's version" do
      assert Plugin.version() == "#{Application.spec(:beamdash, :vsn)}"
      assert Plugin.version() == Mix.Project.config()[:version]
    end

    test "switch_path is the Nodes tab's link that switches to a node" do
      assert Plugin.switch_path(:"kv2@127.0.0.1") == "/nodes?switch=kv2%40127.0.0.1"

      assert Plugin.switch_path(:"kv2@127.0.0.1", "/plugins/riak_core_plugin/ring") ==
               "/nodes?switch=kv2%40127.0.0.1&return=%2Fplugins%2Friak_core_plugin%2Fring"
    end

    test "process_path is the Processes tab's link to a pid" do
      pid = :erlang.list_to_pid(~c"<0.85.0>")
      assert Plugin.process_path(pid) == "/?pid=%3C0.85.0%3E"
    end
  end

  describe "Beamdash.Plugin.Format" do
    test "delegates to Beamdash.Format" do
      alias Beamdash.Plugin.Format, as: PF

      assert PF.term({:a, "b"}) == Beamdash.Format.term({:a, "b"})
      assert PF.term({:a, "b"}, :elixir) == Beamdash.Format.term({:a, "b"}, :elixir)

      assert PF.term(String.duplicate("x", 50), :elixir, 10) ==
               Beamdash.Format.term(String.duplicate("x", 50), :elixir, 10)

      assert PF.pid(self()) == Beamdash.Format.pid(self())
      assert PF.pid(self(), :elixir) == Beamdash.Format.pid(self(), :elixir)
      assert PF.mfa({:lists, :map, 2}) == "lists:map/2"
      assert PF.mfa({:lists, :map, 2}, :elixir) == Beamdash.Format.mfa({:lists, :map, 2}, :elixir)
      assert PF.bytes(2048) == Beamdash.Format.bytes(2048)
    end
  end

  describe "use Beamdash.Plugin.Page" do
    test "HelloLive mounts with @plugin, @node, @syntax and the rpc result" do
      {target, node} = start_connected_target()

      session = %{
        "plugin_app" => :hello_plugin,
        "plugin_module" => HelloPlugin,
        "target" => target,
        "syntax" => :elixir
      }

      socket = mount(HelloPlugin.HelloLive, session)

      assert socket.assigns.plugin ==
               Map.put(HelloPlugin.__beamdash_plugin__(), :app, :hello_plugin)

      assert socket.assigns.node == node
      assert socket.assigns.syntax == :elixir
      assert socket.assigns.beamdash_target == target
      assert socket.assigns.remote == {:ok, node}

      html = render(HelloPlugin.HelloLive, socket)
      assert html =~ ~s(id="hello-plugin")
      assert html =~ "Hello from #{node}"
      assert html =~ ~s(id="hello-plugin-rpc")
      assert html =~ "#{node}"
    end

    test "defaults: :erlang syntax, nowhere when disconnected" do
      target = start_target()

      socket =
        mount(HelloPlugin.HelloLive, %{
          "plugin_app" => :hello_plugin,
          "plugin_module" => HelloPlugin,
          "target" => target
        })

      assert socket.assigns.syntax == :erlang
      assert socket.assigns.node == nil
      assert socket.assigns.remote == {:error, :not_connected}
      assert render(HelloPlugin.HelloLive, socket) =~ "Hello from nowhere"
    end

    test "connection events update @node and call connection_changed/2" do
      {peer, node} = Fixture.start_peer()
      on_exit(fn -> Fixture.stop_peer(peer) end)
      target = start_target()

      socket =
        mount(HelloPlugin.HelloLive, %{
          "plugin_app" => :hello_plugin,
          "plugin_module" => HelloPlugin,
          "target" => target
        })

      assert socket.assigns.node == nil

      # mount subscribed this process to the target
      {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie(), target)
      assert_receive {:beamdash_target, {:connected, ^node}} = msg, 5_000

      {:noreply, socket} = HelloPlugin.HelloLive.handle_info(msg, socket)
      assert socket.assigns.node == node
      # HelloLive's connection_changed/2 re-ran the rpc
      assert socket.assigns.remote == {:ok, node}

      :ok = Target.disconnect(target)
      assert_receive {:beamdash_target, {:disconnected, _}} = msg, 5_000
      {:noreply, socket} = HelloPlugin.HelloLive.handle_info(msg, socket)
      assert socket.assigns.node == nil
      assert socket.assigns.remote == {:error, :not_connected}
    end

    test "other messages go to plugin_info/2" do
      target = start_target()

      socket =
        mount(HelloPlugin.HelloLive, %{
          "plugin_app" => :hello_plugin,
          "plugin_module" => HelloPlugin,
          "target" => target
        })

      {:noreply, socket} = HelloPlugin.HelloLive.handle_info({:hello_count, 3}, socket)
      assert socket.assigns.count == 3
    end

    test "a page without callbacks: defaults for everything" do
      mod = unique(BarePage)

      source = """
      defmodule #{inspect(mod)} do
        use Beamdash.Plugin.Page

        def render(assigns), do: ~H[<p id="bare">{@node || "none"}</p>]
      end
      """

      try do
        {_, stderr} = with_io(:stderr, fn -> Code.compile_string(source) end)
        assert stderr == ""

        {peer, node} = Fixture.start_peer()
        on_exit(fn -> Fixture.stop_peer(peer) end)
        target = start_target()

        socket =
          mount(mod, %{
            "plugin_app" => :hello_plugin,
            "plugin_module" => HelloPlugin,
            "target" => target
          })

        assert socket.assigns.plugin.name == "Hello"
        assert render(mod, socket) =~ "none"

        assert {:noreply, ^socket} = mod.handle_info(:anything, socket)

        {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie(), target)
        assert_receive {:beamdash_target, {:connected, ^node}} = msg, 5_000
        {:noreply, socket} = mod.handle_info(msg, socket)
        assert socket.assigns.node == node
        assert render(mod, socket) =~ "#{node}"
      after
        :code.purge(mod)
        :code.delete(mod)
        :code.purge(mod)
      end
    end

    test "a page with @impl annotations compiles without warnings" do
      mod = unique(ImplPage)

      source = """
      defmodule #{inspect(mod)} do
        use Beamdash.Plugin.Page

        @impl true
        def plugin_mount(_params, _session, socket), do: {:ok, socket}

        @impl true
        def handle_event("x", _params, socket), do: {:noreply, socket}

        @impl true
        def render(assigns), do: ~H"<p>hi</p>"
      end
      """

      {_, stderr} = with_io(:stderr, fn -> compile(source, mod) end)
      assert stderr == ""
    end

    test "a page defining handle_info/2 gets a compile error naming plugin_info/2" do
      mod = unique(InfoPage)

      source = """
      defmodule #{inspect(mod)} do
        use Beamdash.Plugin.Page
        def handle_info(_msg, socket), do: {:noreply, socket}
        def render(assigns), do: ~H"<p>hi</p>"
      end
      """

      assert_raise CompileError, ~r/plugin_info\/2/, fn -> compile(source, mod) end
    end

    test "a page defining mount/3 gets a compile error naming plugin_mount/3" do
      mod = unique(MountPage)

      source = """
      defmodule #{inspect(mod)} do
        use Beamdash.Plugin.Page
        def mount(_params, _session, socket), do: {:ok, socket}
        def render(assigns), do: ~H"<p>hi</p>"
      end
      """

      assert_raise CompileError, ~r/plugin_mount\/3/, fn -> compile(source, mod) end
    end
  end
end
