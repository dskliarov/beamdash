defmodule Beamdash.PluginsBuildTest do
  # Beamdash.Plugins.Fetch and Beamdash.Plugins.Build. Everything happens in
  # temp dirs: the fixture plugin is read from test/fixtures, and small broken
  # plugins are written to tmp dirs. async: false because it sets app env and
  # compiles into the running VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Beamdash.Plugins.{Build, Fetch, Spec}

  @moduletag :capture_log

  @fixture Path.expand("../fixtures/plugins/hello_plugin", __DIR__)

  # compiled and loaded at runtime
  @compile {:no_warn_undefined, [HelloPlugin]}

  setup do
    tmp = Path.join(System.tmp_dir!(), "beamdash_build_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    old =
      for key <- [
            :plugins_dir,
            :plugins_allow_local_git,
            :plugins_hex_cmd,
            :plugins_fetch_timeout
          ],
          do: {key, Application.fetch_env(:beamdash, key)}

    on_exit(fn ->
      for {key, res} <- old do
        case res do
          {:ok, v} -> Application.put_env(:beamdash, key, v)
          :error -> Application.delete_env(:beamdash, key)
        end
      end

      File.rm_rf(tmp)
    end)

    %{tmp: tmp}
  end

  # A plugin project in tmp/name with the given mix.exs and lib files
  # ({relative path, source}).
  defp write_plugin(tmp, name, mix_exs, files) do
    root = Path.join(tmp, name)

    for {rel, source} <- [{"mix.exs", mix_exs} | files] do
      path = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, source)
    end

    root
  end

  defp mix_exs(project_extra \\ "", deps) do
    """
    defmodule P.MixProject do
      use Mix.Project
      def project, do: [app: :p#{project_extra}, deps: #{deps}]
    end
    """
  end

  # Fetches hello_plugin with `req`, `hex.info` printing `info_out`; gives
  # the version that was fetched, or the error.
  defp resolve_with(tmp, info_out, req) do
    Application.put_env(:beamdash, :plugins_hex_cmd, fn
      ["hex.info", "hello_plugin"] ->
        {info_out, 0}

      ["hex.package", "fetch", "hello_plugin", _version, "--unpack", "--output", out] ->
        File.mkdir_p!(out)
        File.cp_r!(@fixture, out)
        {"ok", 0}
    end)

    {:ok, spec} = Spec.parse(~s|{:hello_plugin, "#{req}"}|)
    dest = Path.join(tmp, unique_name("dest"))

    case Fetch.fetch(spec, dest) do
      {:ok, %{resolved: version}} -> {:ok, version}
      {:error, msg} -> {:error, msg}
    end
  end

  defp unique_name(prefix), do: "#{prefix}#{System.unique_integer([:positive])}"

  # Cleans up modules a test's plugin may have loaded.
  defp cleanup_modules(modules) do
    Build.unload(modules)
    for m <- modules, do: :code.delete(m)
  end

  describe "read_project/1" do
    test "the fixture", _ do
      assert {:ok, project} = Build.read_project(@fixture)
      assert project.app == :hello_plugin
      assert project.supports == [{:hello_app, "~> 1.0"}]
      assert project.shipped == [{:phoenix_live_view, "~> 1.0"}]
      assert project.beamdash_req == nil
    end

    test "a symlinked mix.exs is refused, not followed", %{tmp: tmp} do
      root = Path.join(tmp, "linked")
      File.mkdir_p!(root)
      File.ln_s!(Path.join(@fixture, "mix.exs"), Path.join(root, "mix.exs"))

      assert {:error, msg} = Build.read_project(root)
      assert msg =~ "mix.exs is a symbolic link"
    end

    test "app: some_call() is refused and never run", %{tmp: tmp} do
      root =
        write_plugin(
          tmp,
          "call",
          """
          defmodule P.MixProject do
            use Mix.Project
            def project, do: [app: System.halt(1), deps: []]
          end
          """,
          []
        )

      assert {:error, msg} = Build.read_project(root)
      assert msg =~ "app"
    end

    test "deps: deps() ++ more() is refused", %{tmp: tmp} do
      root =
        write_plugin(
          tmp,
          "concat",
          """
          defmodule P.MixProject do
            use Mix.Project
            def project, do: [app: :p, deps: deps() ++ more()]
            defp deps, do: [{:hello_app, "~> 1.0", runtime: false}]
            defp more, do: System.halt(1)
          end
          """,
          []
        )

      assert Build.read_project(root) == {:error, "deps must be a literal list in mix.exs"}
    end

    test "deps from a local function that does something else is refused", %{tmp: tmp} do
      root =
        write_plugin(
          tmp,
          "iffy",
          """
          defmodule P.MixProject do
            use Mix.Project
            def project, do: [app: :p, deps: deps()]
            defp deps, do: if(true, do: [], else: [])
          end
          """,
          []
        )

      assert Build.read_project(root) == {:error, "deps must be a literal list in mix.exs"}
    end

    test "deps in an inline literal list and in `def deps`", %{tmp: tmp} do
      inline =
        write_plugin(
          tmp,
          "inline",
          mix_exs(~S|{:a_app, "~> 1.0", runtime: false}| |> then(&"[#{&1}]")),
          []
        )

      assert {:ok, %{supports: [{:a_app, "~> 1.0"}]}} = Build.read_project(inline)

      public =
        write_plugin(
          tmp,
          "public",
          """
          defmodule P.MixProject do
            use Mix.Project
            def project, do: [app: :p, deps: deps()]
            def deps do
              [{:b_app, runtime: false}]
            end
          end
          """,
          []
        )

      assert {:ok, %{supports: [{:b_app, nil}]}} = Build.read_project(public)
    end

    test "a beamdash requirement that does not match", %{tmp: tmp} do
      root =
        write_plugin(
          tmp,
          "bd",
          mix_exs(
            ~S|[{:beamdash, "~> 99.0", runtime: false}, {:a_app, "~> 1.0", runtime: false}]|
          ),
          []
        )

      assert {:error, msg} = Build.read_project(root)
      assert msg == "needs beamdash ~> 99.0, this is #{Beamdash.Plugin.version()}"
    end

    test "a beamdash dep with a path and no requirement is fine", %{tmp: tmp} do
      root =
        write_plugin(
          tmp,
          "bdpath",
          mix_exs(
            ~S|[{:beamdash, path: "../x", only: [:dev], runtime: false}, {:a_app, "~> 1.0", runtime: false}]|
          ),
          []
        )

      assert {:ok, %{beamdash_req: nil, supports: [{:a_app, "~> 1.0"}]}} =
               Build.read_project(root)
    end

    test "a beamdash requirement that matches is recorded", %{tmp: tmp} do
      root =
        write_plugin(
          tmp,
          "bdok",
          mix_exs(
            ~s|[{:beamdash, ">= 0.0.0", runtime: false}, {:a_app, "~> 1.0", runtime: false}]|
          ),
          []
        )

      assert {:ok, %{beamdash_req: ">= 0.0.0"}} = Build.read_project(root)
    end

    test "a runtime dep beamdash doesn't ship", %{tmp: tmp} do
      root = write_plugin(tmp, "lp", mix_exs(~S|[{:left_pad, "~> 1.0"}]|), [])
      assert {:error, msg} = Build.read_project(root)
      assert msg == "needs left_pad, which beamdash doesn't ship"
    end

    test "a shipped library at a version that doesn't match", %{tmp: tmp} do
      root =
        write_plugin(
          tmp,
          "plv",
          mix_exs(~S|[{:phoenix_live_view, "~> 99.0"}, {:a_app, "~> 1.0", runtime: false}]|),
          []
        )

      assert {:error, msg} = Build.read_project(root)
      assert msg =~ "phoenix_live_view"
      assert msg =~ "~> 99.0"
    end

    test "only shipped deps: declare the supported application", %{tmp: tmp} do
      root = write_plugin(tmp, "none", mix_exs(~S|[{:phoenix_live_view, "~> 1.0"}]|), [])

      assert Build.read_project(root) ==
               {:error,
                "declare the application it supports as a runtime: false dependency in mix.exs"}
    end

    test "only: :dev with runtime: false still counts as a supported app", %{tmp: tmp} do
      root =
        write_plugin(
          tmp,
          "riak",
          mix_exs(~S|[{:riak_core, ">= 0.0.0", only: :dev, runtime: false}]|),
          []
        )

      assert {:ok, %{supports: [{:riak_core, ">= 0.0.0"}]}} = Build.read_project(root)
    end

    test "a bad requirement on a supported app", %{tmp: tmp} do
      root = write_plugin(tmp, "badreq", mix_exs(~S|[{:a_app, "nonsense", runtime: false}]|), [])
      assert {:error, msg} = Build.read_project(root)
      assert msg =~ "a_app"
    end

    test "a module attribute in a dep names the dep", %{tmp: tmp} do
      root =
        write_plugin(
          tmp,
          "attr",
          """
          defmodule P.MixProject do
            use Mix.Project
            @req "~> 1.0"
            def project, do: [app: :p, deps: [{:a_app, @req, runtime: false}]]
          end
          """,
          []
        )

      assert {:error, msg} = Build.read_project(root)
      assert msg =~ "a_app"
    end

    test "no mix.exs, no app:, no atoms made from the file", %{tmp: tmp} do
      assert {:error, _} = Build.read_project(Path.join(tmp, "nowhere"))

      root =
        write_plugin(tmp, "noapp", "defmodule P.MixProject do\n  def project, do: []\nend\n", [])

      assert {:error, msg} = Build.read_project(root)
      assert msg =~ "app"

      name = "zz_never_seen_#{System.unique_integer([:positive])}"
      weird = write_plugin(tmp, "weird", mix_exs(~s|[{:"#{name}_dep", "~> 1.0"}]|), [])
      assert {:error, _} = Build.read_project(weird)

      assert_raise ArgumentError, fn -> String.to_existing_atom(name <> "_dep") end
    end

    test "an app name that is not a valid plugin name", %{tmp: tmp} do
      root =
        write_plugin(
          tmp,
          "badname",
          """
          defmodule P.MixProject do
            use Mix.Project
            def project, do: [app: :"Bad-Name", deps: [{:a_app, "~> 1.0", runtime: false}]]
          end
          """,
          []
        )

      assert {:error, msg} = Build.read_project(root)
      assert msg =~ "app"
    end
  end

  describe "scan/1" do
    test "the fixture" do
      assert {:ok, %{prefix: HelloPlugin, modules: modules}} = Build.scan(@fixture)
      assert Enum.sort(modules) == [HelloPlugin, HelloPlugin.HelloLive]
    end

    test "refuses a module beamdash already has, before compiling", %{tmp: tmp} do
      md5 = Beamdash.Format.module_info(:md5)

      root =
        write_plugin(tmp, "clash", mix_exs("[]"), [
          {"lib/format.ex", "defmodule Beamdash.Format do\n  def x, do: 1\nend\n"}
        ])

      assert {:error, msg} = Build.scan(root)
      assert msg =~ "Beamdash.Format"
      assert Beamdash.Format.module_info(:md5) == md5
    end

    test "refuses an OTP module name", %{tmp: tmp} do
      root =
        write_plugin(tmp, "otp", mix_exs("[]"), [
          {"lib/a.ex", "defmodule :lists do\n  def x, do: 1\nend\n"}
        ])

      assert {:error, _} = Build.scan(root)
    end

    test "refuses two top-level prefixes", %{tmp: tmp} do
      a = unique_name("PrefA")
      b = unique_name("PrefB")

      root =
        write_plugin(tmp, "two", mix_exs("[]"), [
          {"lib/a.ex", "defmodule #{a} do\nend\n"},
          {"lib/b.ex", "defmodule #{b} do\nend\n"}
        ])

      assert {:error, msg} = Build.scan(root)
      assert msg =~ "one"
    end

    test "the prefix must be a module the plugin defines", %{tmp: tmp} do
      a = unique_name("NoEntry")

      root =
        write_plugin(tmp, "noentry", mix_exs("[]"), [
          {"lib/a.ex", "defmodule #{a}.One do\nend\ndefmodule #{a}.Two do\nend\n"}
        ])

      assert {:error, msg} = Build.scan(root)
      assert msg =~ a
    end

    test "nested modules join their parent, and alias __MODULE__ is ignored", %{tmp: tmp} do
      a = unique_name("Nest")

      root =
        write_plugin(tmp, "nest", mix_exs("[]"), [
          {"lib/a.ex",
           """
           defmodule #{a} do
             alias __MODULE__
             defmodule Inner do
               defmodule Deep do
               end
             end
           end
           """}
        ])

      assert {:ok, %{prefix: prefix, modules: modules}} = Build.scan(root)
      assert prefix == Module.concat([a])

      assert Enum.sort(modules) ==
               Enum.sort([
                 prefix,
                 Module.concat(prefix, Inner),
                 Module.concat([prefix, Inner, Deep])
               ])
    end

    test "defimpl for a module outside the prefix is refused", %{tmp: tmp} do
      a = unique_name("Impl")

      root =
        write_plugin(tmp, "impl", mix_exs("[]"), [
          {"lib/a.ex",
           """
           defmodule #{a} do
           end
           defimpl String.Chars, for: Map do
             def to_string(_), do: "x"
           end
           """}
        ])

      assert {:error, msg} = Build.scan(root)
      assert msg =~ "defimpl"
    end

    test "defimpl for a module under the prefix is fine", %{tmp: tmp} do
      a = unique_name("ImplOk")

      root =
        write_plugin(tmp, "implok", mix_exs("[]"), [
          {"lib/a.ex",
           """
           defmodule #{a} do
             defstruct []
           end
           defimpl String.Chars, for: #{a} do
             def to_string(_), do: "x"
           end
           """}
        ])

      assert {:ok, %{prefix: prefix, modules: modules}} = Build.scan(root)
      assert prefix == Module.concat([a])
      assert prefix in modules
    end

    test "a syntax error in a source file is an error naming the file", %{tmp: tmp} do
      root =
        write_plugin(tmp, "syn", mix_exs("[]"), [
          {"lib/a.ex", "defmodule A do\n  def f(, do: 1\nend\n"}
        ])

      assert {:error, msg} = Build.scan(root)
      assert msg =~ "a.ex"
    end

    test "no source files", %{tmp: tmp} do
      root = write_plugin(tmp, "empty", mix_exs("[]"), [])
      assert {:error, _} = Build.scan(root)
    end

    test "rebuilding: modules of this same plugin are allowed", %{tmp: tmp} do
      a = unique_name("Rebuild")
      mod = Module.concat([a])

      root =
        write_plugin(tmp, "rebuild", mix_exs("[]"), [
          {"lib/a.ex", "defmodule #{a} do\n  def x, do: 1\nend\n"}
        ])

      ebin = Path.join(tmp, "rebuild_ebin")
      File.mkdir_p!(ebin)

      try do
        assert {:ok, [^mod]} = compile_quiet(root, ebin)
        assert :ok = Build.load([mod], ebin)
        assert :code.is_loaded(mod) != false

        assert {:error, _} = Build.scan(root)
        assert {:ok, %{prefix: ^mod}} = Build.scan(root, allow: [mod])
      after
        Code.delete_path(ebin)
        cleanup_modules([mod])
      end
    end
  end

  defp compile_quiet(src, ebin) do
    {result, _} = with_io(:stderr, fn -> Build.compile(src, ebin) end)
    result
  end

  describe "compile/2 and check/2" do
    @tag :fixture_compile
    test "the fixture compiles and checks", %{tmp: tmp} do
      ebin = Path.join(tmp, "ebin")
      File.mkdir_p!(ebin)

      try do
        assert {:ok, modules} = compile_quiet(@fixture, ebin)
        assert Enum.sort(modules) == [HelloPlugin, HelloPlugin.HelloLive]

        assert {:ok, %{name: "Hello", pages: [%{slug: "hello", module: HelloPlugin.HelloLive}]}} =
                 Build.check(modules, HelloPlugin, ebin)
      after
        Code.delete_path(ebin)
        cleanup_modules([HelloPlugin, HelloPlugin.HelloLive])
      end
    end

    test "a syntax error names file:line and leaves nothing loaded", %{tmp: tmp} do
      a = unique_name("Syn")

      root =
        write_plugin(tmp, "syn", mix_exs("[]"), [
          {"lib/ok.ex", "defmodule #{a} do\n  def x, do: 1\nend\n"},
          {"lib/bad.ex", "defmodule #{a}.Bad do\n  def f(, do: 1\nend\n"}
        ])

      ebin = Path.join(tmp, "syn_ebin")
      File.mkdir_p!(ebin)

      assert {:error, msg} = compile_quiet(root, ebin)
      assert msg =~ ~r/bad\.ex:\d+/
      assert :code.is_loaded(Module.concat([a])) == false
      assert :code.is_loaded(Module.concat(a, Bad)) == false
    end

    test "a call to a module beamdash doesn't have is refused", %{tmp: tmp} do
      a = unique_name("Calls")
      mod = Module.concat([a])

      root =
        write_plugin(tmp, "calls", mix_exs("[]"), [
          {"lib/a.ex",
           """
           defmodule #{a} do
             use Beamdash.Plugin, name: "C", pages: [{"p", "P", #{a}.Page}]
             def a, do: NotShipped.call()
             def b, do: :hello_app_mod.f()
           end
           defmodule #{a}.Page do
             use Beamdash.Plugin.Page
             def render(assigns), do: ~H"<p>x</p>"
           end
           """}
        ])

      ebin = Path.join(tmp, "calls_ebin")
      File.mkdir_p!(ebin)

      try do
        assert {:ok, modules} = compile_quiet(root, ebin)
        assert {:error, msg} = Build.check(modules, mod, ebin)
        assert msg =~ "NotShipped"
        assert msg =~ "hello_app_mod"
        assert msg =~ "Beamdash.Plugin.rpc"
      after
        Code.delete_path(ebin)
        cleanup_modules([mod, Module.concat(mod, Page)])
      end
    end

    test "passing the module name to Beamdash.Plugin.rpc compiles and checks", %{tmp: tmp} do
      a = unique_name("RpcOk")
      mod = Module.concat([a])

      root =
        write_plugin(tmp, "rpcok", mix_exs("[]"), [
          {"lib/a.ex",
           """
           defmodule #{a} do
             use Beamdash.Plugin, name: "C", pages: [{"p", "P", #{a}.Page}]
             def a, do: Beamdash.Plugin.rpc(:hello_app_mod, :f, [])
           end
           defmodule #{a}.Page do
             use Beamdash.Plugin.Page
             def render(assigns), do: ~H"<p>x</p>"
           end
           """}
        ])

      ebin = Path.join(tmp, "rpcok_ebin")
      File.mkdir_p!(ebin)

      try do
        assert {:ok, modules} = compile_quiet(root, ebin)
        assert {:ok, %{name: "C"}} = Build.check(modules, mod, ebin)
      after
        Code.delete_path(ebin)
        cleanup_modules([mod, Module.concat(mod, Page)])
      end
    end

    test "check: no entry module, and a page that is not a compiled module", %{tmp: tmp} do
      a = unique_name("Chk")
      mod = Module.concat([a])

      root =
        write_plugin(tmp, "chk", mix_exs("[]"), [
          {"lib/a.ex", "defmodule #{a} do\n  def x, do: 1\nend\n"}
        ])

      ebin = Path.join(tmp, "chk_ebin")
      File.mkdir_p!(ebin)

      try do
        assert {:ok, modules} = compile_quiet(root, ebin)
        assert {:error, msg} = Build.check(modules, mod, ebin)
        assert msg =~ "__beamdash_plugin__"
      after
        Code.delete_path(ebin)
        cleanup_modules([mod])
      end

      b = unique_name("Chk")
      bmod = Module.concat([b])

      root2 =
        write_plugin(tmp, "chk2", mix_exs("[]"), [
          {"lib/a.ex",
           """
           defmodule #{b} do
             use Beamdash.Plugin, name: "C", pages: [{"p", "P", Some.Missing.Page}]
           end
           """}
        ])

      ebin2 = Path.join(tmp, "chk2_ebin")
      File.mkdir_p!(ebin2)

      try do
        assert {:ok, modules} = compile_quiet(root2, ebin2)
        assert {:error, msg} = Build.check(modules, bmod, ebin2)
        assert msg =~ "Some.Missing.Page"
      after
        Code.delete_path(ebin2)
        cleanup_modules([bmod])
      end
    end

    test "check: a hand-written __beamdash_plugin__/0 with bad pages is refused", %{tmp: tmp} do
      cases = [
        {~S|%{name: "C", pages: [%{slug: "p", label: "P"}]}|, ~r/invalid page/},
        {~S|%{name: "C", pages: [%{slug: "p", label: :p, module: X.P}]}|, ~r/invalid page/},
        {~S|%{name: "C", pages: [%{slug: "Bad", label: "P", module: X.P}]}|, ~r/invalid page/},
        {~S|%{name: "C", pages: [%{slug: "p\n", label: "P", module: X.P}]}|, ~r/invalid page/},
        {~S|%{name: "C", pages: [%{slug: "p", label: "P", module: "X.P"}]}|, ~r/invalid page/},
        {~S|%{name: "C", pages: [:junk]}|, ~r/invalid page/},
        {~S|%{name: :c, pages: []}|, ~r/plugin declaration/}
      ]

      for {{decl, expected}, i} <- Enum.with_index(cases) do
        a = unique_name("Hand")
        mod = Module.concat([a])

        root =
          write_plugin(tmp, "hand#{i}", mix_exs("[]"), [
            {"lib/a.ex", "defmodule #{a} do\n  def __beamdash_plugin__, do: #{decl}\nend\n"}
          ])

        ebin = Path.join(tmp, "hand#{i}_ebin")
        File.mkdir_p!(ebin)

        try do
          assert {:ok, modules} = compile_quiet(root, ebin)
          assert {:error, msg} = Build.check(modules, mod, ebin), decl
          assert msg =~ expected, msg
        after
          Code.delete_path(ebin)
          cleanup_modules([mod])
        end
      end
    end

    test "unload purges and deletes modules" do
      {:module, _} = Code.ensure_loaded(Beamdash.Plugins.Spec)
      # a throwaway module compiled from a string
      [{mod, _}] =
        Code.compile_string("defmodule UnloadMe#{System.unique_integer([:positive])} do end")

      assert :code.is_loaded(mod) != false
      Build.unload([mod])
      assert :code.is_loaded(mod) == false
    end
  end

  describe "scan/1 sees the names the compiler will use" do
    # Each source would define (or replace) a module outside the plugin's
    # prefix. Each is refused by scan, before compiling.
    defp scan_source(tmp, source) do
      a = unique_name("Probe")

      root =
        write_plugin(tmp, a, mix_exs("[]"), [{"lib/a.ex", String.replace(source, "PROBE", a)}])

      Build.scan(root)
    end

    test "a nested defimpl for an outside module (Inspect.Map)", %{tmp: tmp} do
      assert {:error, msg} =
               scan_source(tmp, """
               defmodule PROBE do
                 defimpl Inspect, for: Map do
                   def inspect(_, _), do: "x"
                 end
               end
               """)

      assert msg =~ "defimpl Inspect, for: Map"
    end

    test "a nested defimpl is named Proto.Target, not nested under the parent", %{tmp: tmp} do
      a = unique_name("Probe")

      root =
        write_plugin(tmp, a, mix_exs("[]"), [
          {"lib/a.ex",
           """
           defmodule #{a} do
             defstruct []
             defimpl String.Chars do
               def to_string(_), do: "x"
             end
           end
           """}
        ])

      assert {:ok, %{modules: modules}} = Build.scan(root)
      prefix = Module.concat([a])
      assert Module.concat(String.Chars, prefix) in modules
      refute Module.concat([prefix, String.Chars]) in modules
    end

    test "a nested defmodule Elixir.Beamdash.Format", %{tmp: tmp} do
      assert {:error, msg} =
               scan_source(tmp, """
               defmodule PROBE do
                 defmodule Elixir.Beamdash.Format do
                 end
               end
               """)

      assert msg =~ "Beamdash"
    end

    test "a top-level defmodule Elixir.Beamdash.Format", %{tmp: tmp} do
      assert {:error, msg} = scan_source(tmp, "defmodule Elixir.Beamdash.Format do\nend\n")
      assert msg =~ "Beamdash.Format"
    end

    test "alias Beamdash, as: X then defmodule X.Format", %{tmp: tmp} do
      assert {:error, msg} =
               scan_source(tmp, """
               defmodule PROBE do
                 alias Beamdash, as: X
                 defmodule X.Format do
                 end
               end
               """)

      assert msg =~ "alias"
    end

    test "alias Beamdash.Format then defmodule Format (an alias in scope)", %{tmp: tmp} do
      assert {:error, msg} =
               scan_source(tmp, """
               alias Beamdash.Format
               defmodule PROBE do
                 defmodule Format.Inner do
                 end
               end
               """)

      assert msg =~ "Format is an alias"
    end

    test "alias Beamdash.{Format} then defmodule Format (a multi-alias)", %{tmp: tmp} do
      assert {:error, msg} =
               scan_source(tmp, """
               alias Beamdash.{Format}
               defmodule Format do
               end
               """)

      assert msg =~ "Format is an alias"
    end

    test "an alias under the plugin's own prefix is fine", %{tmp: tmp} do
      a = unique_name("Probe")

      root =
        write_plugin(tmp, a, mix_exs("[]"), [
          {"lib/a.ex",
           """
           defmodule #{a} do
             alias __MODULE__
             alias #{a}.Pages, as: P
             def f, do: P.x()
           end
           """}
        ])

      assert {:ok, _} = Build.scan(root)
    end

    for {what, call} <- [
          {"Kernel.defmodule", "Kernel.defmodule(Beamdash.Format, do: nil)"},
          {"Module.create", "Module.create(Beamdash.Format, nil, Macro.Env.location(__ENV__))"},
          {"Code.compile_string", ~S|Code.compile_string("defmodule Beamdash.Format do end")|},
          {":code.load_binary", ~S|:code.load_binary(Beamdash.Format, ~c"x", <<>>)|}
        ] do
      test "#{what} is refused", %{tmp: tmp} do
        assert {:error, msg} =
                 scan_source(tmp, """
                 defmodule PROBE do
                   @x #{unquote(call)}
                 end
                 """)

        assert msg =~ unquote(what)
        assert msg =~ "not allowed"
      end
    end

    test "a defmodule inside a tuple is seen", %{tmp: tmp} do
      assert {:error, msg} =
               scan_source(tmp, """
               defmodule PROBE do
                 @x {defmodule(Elixir.Beamdash.Format, do: nil), 1}
               end
               """)

      assert msg =~ "Beamdash"
    end
  end

  describe "a compiled module the scan didn't see" do
    test "is refused, unloaded, and the host module keeps its code", %{tmp: tmp} do
      md5 = Beamdash.Format.module_info(:md5)
      which = :code.which(Beamdash.Format)
      a = unique_name("Gen")
      prefix = Module.concat([a])
      generated = Module.concat(prefix, Generated)

      # A module made by a macro at compile time: the scan reads the quoted
      # defmodule as Maker.Generated, but it compiles as <prefix>.Generated.
      root =
        write_plugin(tmp, "gen", mix_exs("[]"), [
          {"lib/a.ex",
           """
           defmodule #{a}.Maker do
             defmacro make do
               quote do
                 defmodule Generated do
                   def x, do: 1
                 end
               end
             end
           end
           """},
          {"lib/b.ex",
           """
           defmodule #{a} do
             require #{a}.Maker
             #{a}.Maker.make()
           end
           """}
        ])

      ebin = Path.join(tmp, "gen_ebin")

      try do
        {:ok, %{modules: scanned}} = Build.scan(root)
        refute generated in scanned
        assert Module.concat([prefix, Maker, Generated]) in scanned
        ebin_paths = fn -> Enum.filter(:code.get_path(), &(List.to_string(&1) =~ "gen_ebin")) end

        {result, _} = with_io(:stderr, fn -> Build.compile(root, ebin, scanned) end)
        assert {:error, msg} = result
        assert msg =~ inspect(generated)
        assert ebin_paths.() == []

        for m <- [prefix, generated, Module.concat(prefix, Maker)],
            do: assert(:code.is_loaded(m) == false)

        assert Beamdash.Format.module_info(:md5) == md5
        assert :code.which(Beamdash.Format) == which
      after
        cleanup_modules([prefix, generated, Module.concat(prefix, Maker)])
        File.rm_rf(ebin)
      end
    end

    test "a beam named like a host module: check fails, host code untouched", %{tmp: tmp} do
      md5 = Beamdash.Format.module_info(:md5)
      which = :code.which(Beamdash.Format)
      a = unique_name("Host")
      prefix = Module.concat([a])

      root =
        write_plugin(tmp, "host", mix_exs("[]"), [
          {"lib/a.ex",
           """
           defmodule #{a} do
             use Beamdash.Plugin, name: "H", pages: [{"p", "P", #{a}.Page}]
           end
           defmodule #{a}.Page do
             use Beamdash.Plugin.Page
             def render(assigns), do: ~H"<p>x</p>"
           end
           """}
        ])

      ebin = Path.join(tmp, "host_ebin")

      try do
        assert {:ok, modules} = compile_quiet(root, ebin)
        # a stray beam in ebin with a host module's name, as if compiled there
        File.cp!(List.to_string(which), Path.join(ebin, "Elixir.Beamdash.Format.beam"))

        assert {:error, msg} = Build.check(modules ++ [Beamdash.Format], prefix, ebin)
        assert msg =~ "Beamdash.Format"
        assert {:error, _} = Build.load(modules ++ [Beamdash.Format], ebin)

        assert Beamdash.Format.module_info(:md5) == md5
        assert :code.which(Beamdash.Format) == which
        assert :code.is_loaded(prefix) == false
      after
        cleanup_modules([prefix, Module.concat(prefix, Page)])
      end
    end

    test "compile leaves the ebin off the code path; load uses the files", %{tmp: tmp} do
      ebin = Path.join(tmp, "path_ebin")

      try do
        assert {:ok, modules} = compile_quiet(@fixture, ebin)
        refute Enum.any?(:code.get_path(), &(List.to_string(&1) =~ "path_ebin"))
        assert :code.is_loaded(HelloPlugin) == false
        assert {:ok, %{name: "Hello"}} = Build.check(modules, HelloPlugin, ebin)
        assert :code.is_loaded(HelloPlugin) == false

        assert :ok = Build.load(modules, ebin)
        assert HelloPlugin.__beamdash_plugin__().name == "Hello"
        assert List.to_string(:code.which(HelloPlugin)) =~ "path_ebin"
      after
        cleanup_modules([HelloPlugin, HelloPlugin.HelloLive])
      end
    end
  end

  describe "install_dir/1 and plugins_dir/0" do
    test "plugins_dir reads the app env, with a default" do
      Application.put_env(:beamdash, :plugins_dir, "/x/y")
      assert Build.plugins_dir() == "/x/y"
      assert Build.install_dir(:foo) == "/x/y/foo"

      assert Build.default_plugins_dir() ==
               Path.join(:filename.basedir(:user_config, "beamdash"), "plugins")
    end
  end

  describe "Fetch" do
    defp git!(dir, args) do
      {out, 0} =
        System.cmd(
          "git",
          ["-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false" | args],
          cd: dir,
          stderr_to_stdout: true
        )

      out
    end

    defp make_repo(tmp) do
      repo = Path.join(tmp, "repo")
      File.mkdir_p!(repo)
      File.cp_r!(@fixture, repo)
      git!(repo, ["init", "-q"])
      git!(repo, ["add", "-A"])
      git!(repo, ["commit", "-q", "-m", "init"])
      git!(repo, ["tag", "0.1.0"])
      repo
    end

    test "git: a tag", %{tmp: tmp} do
      Application.put_env(:beamdash, :plugins_allow_local_git, true)
      repo = make_repo(tmp)
      {:ok, spec} = Spec.parse(~s|{:hello_plugin, git: "#{repo}", tag: "0.1.0"}|)
      dest = Path.join(tmp, "dest")
      File.mkdir_p!(dest)

      assert {:ok, %{src: src, resolved: resolved}} = Fetch.fetch(spec, dest)
      assert src == Path.join(dest, "src")
      assert File.regular?(Path.join(src, "mix.exs"))
      assert resolved =~ ~r/\A[0-9a-f]{40}\z/
      assert resolved == String.trim(git!(repo, ["rev-parse", "HEAD"]))
    end

    test "git: a ref (full clone, then checkout)", %{tmp: tmp} do
      Application.put_env(:beamdash, :plugins_allow_local_git, true)
      repo = make_repo(tmp)
      first = String.trim(git!(repo, ["rev-parse", "HEAD"]))
      File.write!(Path.join(repo, "extra.txt"), "x")
      git!(repo, ["add", "-A"])
      git!(repo, ["commit", "-q", "-m", "second"])

      {:ok, spec} = Spec.parse(~s|{:hello_plugin, git: "#{repo}", ref: "#{first}"}|)
      dest = Path.join(tmp, "dest")
      File.mkdir_p!(dest)

      assert {:ok, %{src: src, resolved: ^first}} = Fetch.fetch(spec, dest)
      refute File.exists?(Path.join(src, "extra.txt"))
    end

    test "git: the default branch", %{tmp: tmp} do
      Application.put_env(:beamdash, :plugins_allow_local_git, true)
      repo = make_repo(tmp)
      {:ok, spec} = Spec.parse(~s|{:hello_plugin, git: "#{repo}"}|)
      dest = Path.join(tmp, "dest")
      File.mkdir_p!(dest)
      assert {:ok, %{resolved: resolved}} = Fetch.fetch(spec, dest)
      assert resolved =~ ~r/\A[0-9a-f]{40}\z/
    end

    test "git: a bad URL returns git's message", %{tmp: tmp} do
      Application.put_env(:beamdash, :plugins_allow_local_git, true)
      {:ok, spec} = Spec.parse(~s|{:hello_plugin, git: "#{tmp}/no/such/repo"}|)
      dest = Path.join(tmp, "dest")
      File.mkdir_p!(dest)

      assert {:error, msg} = Fetch.fetch(spec, dest)
      assert msg =~ "no/such/repo"
    end

    test "git: a missing tag", %{tmp: tmp} do
      Application.put_env(:beamdash, :plugins_allow_local_git, true)
      repo = make_repo(tmp)
      {:ok, spec} = Spec.parse(~s|{:hello_plugin, git: "#{repo}", tag: "9.9.9"}|)
      dest = Path.join(tmp, "dest")
      File.mkdir_p!(dest)
      assert {:error, msg} = Fetch.fetch(spec, dest)
      assert msg =~ "9.9.9"
    end

    test "hex: resolves the highest matching version and unpacks it", %{tmp: tmp} do
      test_pid = self()

      Application.put_env(:beamdash, :plugins_hex_cmd, fn
        ["hex.info", "hello_plugin"] ->
          {"A plugin.\n\nConfig: {:hello_plugin, \"~> 0.2\"}\n\nRecent releases:\n  0.2.0 (2026-01-02)\n  0.1.0 (2026-01-01)\n\nDownloads:\n  x\n",
           0}

        ["hex.package", "fetch", "hello_plugin", version, "--unpack", "--output", out] ->
          send(test_pid, {:fetched, version, out})
          File.mkdir_p!(out)
          File.cp_r!(@fixture, out)
          {"hello_plugin v#{version} extracted\n", 0}
      end)

      {:ok, spec} = Spec.parse(~S|{:hello_plugin, "~> 0.1"}|)
      dest = Path.join(tmp, "dest")
      File.mkdir_p!(dest)

      assert {:ok, %{src: src, resolved: "0.2.0"}} = Fetch.fetch(spec, dest)
      assert src == Path.join(dest, "src")
      assert File.regular?(Path.join(src, "mix.exs"))
      assert_received {:fetched, "0.2.0", ^src}
    end

    test "hex: a requirement the listed releases don't satisfy", %{tmp: tmp} do
      Application.put_env(:beamdash, :plugins_hex_cmd, fn
        ["hex.info", _] ->
          {"Recent releases:\n  0.2.0 (2026-01-02)\n  0.1.0 (2026-01-01)\n  ...\n", 0}
      end)

      {:ok, spec} = Spec.parse(~S|{:hello_plugin, "~> 5.0"}|)
      dest = Path.join(tmp, "dest")
      File.mkdir_p!(dest)

      assert {:error, msg} = Fetch.fetch(spec, dest)
      assert msg =~ "~> 5.0"
      assert msg =~ "older"
      assert msg =~ "exact version"
    end

    test "hex: a failing hex.info and a failing fetch", %{tmp: tmp} do
      {:ok, spec} = Spec.parse(~S|{:hello_plugin, "~> 0.1"}|)
      dest = Path.join(tmp, "dest")
      File.mkdir_p!(dest)

      Application.put_env(:beamdash, :plugins_hex_cmd, fn _ ->
        {"No package with name hello_plugin", 1}
      end)

      assert {:error, msg} = Fetch.fetch(spec, dest)
      assert msg =~ "No package"

      Application.put_env(:beamdash, :plugins_hex_cmd, fn
        ["hex.info", _] -> {"Releases:\n  0.1.0 (2026-01-01)\n", 0}
        _ -> {"boom", 1}
      end)

      assert {:error, msg} = Fetch.fetch(spec, dest)
      assert msg =~ "boom"
    end

    test "hex: a package without mix.exs is refused", %{tmp: tmp} do
      Application.put_env(:beamdash, :plugins_hex_cmd, fn
        ["hex.info", _] ->
          {"Recent releases:\n  0.1.0 (2026-01-01)\n", 0}

        [_, _, _, _, _, _, out] ->
          File.mkdir_p!(out)
          {"ok", 0}
      end)

      {:ok, spec} = Spec.parse(~S|{:hello_plugin, "~> 0.1"}|)
      dest = Path.join(tmp, "dest")
      File.mkdir_p!(dest)
      assert {:error, msg} = Fetch.fetch(spec, dest)
      assert msg =~ "mix.exs"
    end

    # The shape Hex 2.5+ prints (lib/mix/tasks/hex.info.ex format_releases/2):
    # "\nRecent releases:\n", then "  <version> (<date>)" per release, with
    # " (retired)" after a retired one (yellow on a terminal), then "  ...".
    test "hex: the real hex.info output (Hex 2.5+), retired releases skipped", %{tmp: tmp} do
      out =
        "A plugin.\n\nConfig: {:hello_plugin, \"~> 0.3\"}\nLocked version: 0.1.0\n\n" <>
          "Recent releases:\n" <>
          "  \e[33m0.3.0 (2026-03-01) (retired)\e[0m\n" <>
          "  0.2.1 (2026-02-01)\n" <>
          "  0.2.0-rc.1 (2026-01-15)\n" <>
          "  0.2.0\n" <>
          "  ...\n\n" <>
          "Downloads:\n  1,234 all time\n  56 this week\n\n" <>
          "Licenses: Apache-2.0\nLinks:\n  GitHub: https://example.com\n"

      assert resolve_with(tmp, out, "~> 0.2") == {:ok, "0.2.1"}
      assert resolve_with(tmp, out, ">= 0.3.0") |> elem(0) == :error
    end

    # The shape Hex up to 2.4 printed: one line, comma separated, retired
    # ones marked " (retired)", and ", ..." when there are more.
    test "hex: the one-line Releases: list of older Hex versions", %{tmp: tmp} do
      out =
        "A plugin.\n\nConfig: {:hello_plugin, \"~> 0.3\"}\n" <>
          "Releases: 0.3.0 (retired), 0.2.1, 0.2.0, 0.1.0, ...\n\n" <>
          "Licenses: MIT\n"

      assert resolve_with(tmp, out, "~> 0.2") == {:ok, "0.2.1"}
      assert resolve_with(tmp, out, "~> 0.1.0") == {:ok, "0.1.0"}
    end

    test "hex: Hex not installed fails fast with a clear message", %{tmp: tmp} do
      prompt =
        "Mix requires the Hex package manager to fetch dependencies\n" <>
          ~s|Shall I install Hex? (if running non-interactively, use "mix local.hex --force") [Yn] | <>
          ~s|** (Mix) The task "hex.info" could not be found\n|

      Application.put_env(:beamdash, :plugins_hex_cmd, fn _ -> {prompt, 1} end)
      dest = Path.join(tmp, "dest")

      {:ok, spec} = Spec.parse(~S|{:hello_plugin, "~> 0.1"}|)
      assert {:error, msg} = Fetch.fetch(spec, dest)
      assert msg =~ "Hex is not installed"
      assert msg =~ "mix local.hex"

      # an exact version skips hex.info and still says so
      {:ok, spec} = Spec.parse(~S|{:hello_plugin, "== 0.1.0"}|)
      assert {:error, msg} = Fetch.fetch(spec, dest)
      assert msg =~ "Hex is not installed"
    end

    test "run_cmd answers a prompt from :input instead of waiting" do
      sh = System.find_executable("sh")

      assert Fetch.run_cmd(sh, ["-c", "read x; echo got:$x"], input: "n\n") ==
               {:ok, {"got:n\n", 0}}
    end

    test "path: a folder inside the plugins dir is refused", %{tmp: tmp} do
      plugins = Path.join(tmp, "plugins")
      inside = Path.join(plugins, "hello_plugin")
      File.mkdir_p!(inside)
      File.cp_r!(@fixture, inside)
      Application.put_env(:beamdash, :plugins_dir, plugins)
      dest = Path.join(tmp, "dest")

      # directly, as the plugins dir itself, and through a symlink outside it
      link = Path.join(tmp, "link")
      File.ln_s!(inside, link)

      for path <- [inside, plugins, link, Path.join(plugins, "../plugins/hello_plugin")] do
        {:ok, spec} = Spec.parse(~s|{:hello_plugin, path: "#{path}"}|)
        assert {:error, msg} = Fetch.fetch(spec, dest), path
        assert msg =~ "inside the plugins folder"
      end

      # reached through a symlinked plugins dir
      alias_dir = Path.join(tmp, "alias")
      File.ln_s!(plugins, alias_dir)
      Application.put_env(:beamdash, :plugins_dir, alias_dir)
      {:ok, spec} = Spec.parse(~s|{:hello_plugin, path: "#{inside}"}|)
      assert {:error, _} = Fetch.fetch(spec, dest)

      assert File.regular?(Path.join(inside, "mix.exs"))
    end

    test "path: the folder itself, unchanged", %{tmp: tmp} do
      {:ok, spec} = Spec.parse(~s|{:hello_plugin, path: "#{@fixture}"}|)
      dest = Path.join(tmp, "dest")
      File.mkdir_p!(dest)

      assert Fetch.fetch(spec, dest) == {:ok, %{src: @fixture, resolved: @fixture}}
      assert File.ls!(dest) == []
    end

    test "path: missing folder, and a folder without mix.exs", %{tmp: tmp} do
      dest = Path.join(tmp, "dest")
      File.mkdir_p!(dest)

      {:ok, spec} = Spec.parse(~s|{:hello_plugin, path: "#{tmp}/missing"}|)
      assert {:error, msg} = Fetch.fetch(spec, dest)
      assert msg =~ "missing"

      empty = Path.join(tmp, "empty")
      File.mkdir_p!(empty)
      {:ok, spec} = Spec.parse(~s|{:hello_plugin, path: "#{empty}"}|)
      assert {:error, msg} = Fetch.fetch(spec, dest)
      assert msg =~ "mix.exs"
    end

    test "run_cmd kills a command that times out", %{tmp: _tmp} do
      Application.put_env(:beamdash, :plugins_fetch_timeout, 200)
      marker = "sleep #{System.unique_integer([:positive]) + 1000}"
      secs = String.replace(marker, "sleep ", "")
      sleep = System.find_executable("sleep")

      {time, result} = :timer.tc(fn -> Fetch.run_cmd(sleep, [secs], []) end)
      assert result == {:error, :timeout}
      assert time < 3_000_000

      Process.sleep(200)
      {ps, _} = System.cmd("ps", ["-axo", "command"])
      refute ps =~ "sleep #{secs}"
    end

    test "run_cmd kills the command's children too on timeout" do
      Application.put_env(:beamdash, :plugins_fetch_timeout, 300)
      secs = Integer.to_string(System.unique_integer([:positive]) + 2000)
      sh = System.find_executable("sh")

      assert Fetch.run_cmd(sh, ["-c", "sleep #{secs} & sleep #{secs}; wait"], []) ==
               {:error, :timeout}

      Process.sleep(200)
      assert {"", 1} = System.cmd("pgrep", ["-f", "^sleep #{secs}$"])
    end

    test "git runs with prompts off and ssh in batch mode", %{tmp: tmp} do
      Application.put_env(:beamdash, :plugins_allow_local_git, true)
      # a fake git on PATH that prints the variables under test (only those:
      # the rest of the environment may hold secrets), then fails
      bin = Path.join(tmp, "bin")
      File.mkdir_p!(bin)
      fake = Path.join(bin, "git")

      File.write!(fake, """
      #!/bin/sh
      echo "GIT_TERMINAL_PROMPT=$GIT_TERMINAL_PROMPT"
      echo "GIT_SSH_COMMAND=$GIT_SSH_COMMAND"
      echo "GIT_ASKPASS=$GIT_ASKPASS"
      echo "SSH_ASKPASS=$SSH_ASKPASS"
      exit 1
      """)

      File.chmod!(fake, 0o755)

      path = System.get_env("PATH")
      ssh = System.get_env("GIT_SSH_COMMAND")
      System.put_env("PATH", bin <> ":" <> path)
      System.delete_env("GIT_SSH_COMMAND")

      try do
        {:ok, spec} = Spec.parse(~s|{:hello_plugin, git: "#{tmp}/repo"}|)
        assert {:error, msg} = Fetch.fetch(spec, Path.join(tmp, "dest"))
        assert msg =~ "GIT_TERMINAL_PROMPT=0"
        assert msg =~ "GIT_SSH_COMMAND=ssh -o BatchMode=yes"
        assert msg =~ ~r/GIT_ASKPASS=\S*false/
        assert msg =~ ~r/SSH_ASKPASS=\S*false/

        # the user's own GIT_SSH_COMMAND is kept
        System.put_env("GIT_SSH_COMMAND", "ssh -i /my/key")
        assert {:error, msg} = Fetch.fetch(spec, Path.join(tmp, "dest2"))
        assert msg =~ "GIT_SSH_COMMAND=ssh -i /my/key"
      after
        System.put_env("PATH", path)

        if ssh,
          do: System.put_env("GIT_SSH_COMMAND", ssh),
          else: System.delete_env("GIT_SSH_COMMAND")
      end
    end

    test "hex: mix runs in a fresh private dir, not a shared one", %{tmp: tmp} do
      test_pid = self()

      Application.put_env(:beamdash, :plugins_hex_cmd, fn args, cwd ->
        %File.Stat{mode: mode, type: :directory} = File.stat!(cwd)
        send(test_pid, {:cwd, cwd, Bitwise.band(mode, 0o777), File.ls!(cwd)})

        case args do
          ["hex.info", _] ->
            {"Recent releases:\n  0.1.0 (2026-01-01)\n", 0}

          [_, _, _, _, _, _, out] ->
            File.mkdir_p!(out)
            File.cp_r!(@fixture, out)
            {"ok", 0}
        end
      end)

      {:ok, spec} = Spec.parse(~S|{:hello_plugin, "~> 0.1"}|)
      dest = Path.join(tmp, "dest")
      assert {:ok, %{resolved: "0.1.0"}} = Fetch.fetch(spec, dest)

      assert_received {:cwd, cwd, 0o700, []}
      assert Path.dirname(cwd) == dest
      assert_received {:cwd, ^cwd, 0o700, []}
      # removed afterwards
      refute File.exists?(cwd)
    end

    test "default_hex_cmd never runs mix in the shared temp dir" do
      # In a fresh dir mix finds no mix.exs, so `mix run` fails with that message.
      {out, status} = Fetch.default_hex_cmd(["run", "-e", "IO.puts(File.cwd!())"])
      assert status != 0
      assert out =~ "mix.exs" or out =~ "not found on PATH"
    end

    test "run_cmd returns output and status" do
      echo = System.find_executable("echo")
      assert Fetch.run_cmd(echo, ["hi"], []) == {:ok, {"hi\n", 0}}
      sh = System.find_executable("sh")
      assert {:ok, {"", 3}} = Fetch.run_cmd(sh, ["-c", "exit 3"], [])
    end

    test "git timing out says so", %{tmp: tmp} do
      Application.put_env(:beamdash, :plugins_fetch_timeout, 1)
      Application.put_env(:beamdash, :plugins_allow_local_git, true)
      repo = make_repo(tmp)
      {:ok, spec} = Spec.parse(~s|{:hello_plugin, git: "#{repo}"}|)
      dest = Path.join(tmp, "dest")
      File.mkdir_p!(dest)
      assert {:error, msg} = Fetch.fetch(spec, dest)
      assert msg == "git timed out after 1 ms"
    end
  end

  describe "safe_rm_rf/1" do
    setup %{tmp: tmp} do
      plugins = Path.join(tmp, "plugins")
      File.mkdir_p!(plugins)
      Application.put_env(:beamdash, :plugins_dir, plugins)
      %{plugins: plugins}
    end

    test "deletes a folder inside the plugins dir", %{plugins: plugins} do
      File.mkdir_p!(Path.join(plugins, "x/ebin"))
      File.write!(Path.join(plugins, "x/ebin/a"), "1")
      assert Build.safe_rm_rf(Path.join(plugins, "x")) == :ok
      refute File.exists?(Path.join(plugins, "x"))
      assert File.dir?(plugins)
    end

    test "a missing folder inside the plugins dir is fine", %{plugins: plugins} do
      assert Build.safe_rm_rf(Path.join(plugins, "nope")) == :ok
    end

    test "refuses the plugins dir itself", %{plugins: plugins} do
      File.write!(Path.join(plugins, "keep"), "1")
      assert {:error, _} = Build.safe_rm_rf(plugins)
      assert {:error, _} = Build.safe_rm_rf(plugins <> "/")
      assert {:error, _} = Build.safe_rm_rf(plugins <> "/.")
      assert File.regular?(Path.join(plugins, "keep"))
    end

    test "refuses paths elsewhere and ../ escapes", %{tmp: tmp, plugins: plugins} do
      elsewhere = Path.join(tmp, "elsewhere")
      File.mkdir_p!(elsewhere)
      outside = Path.join(tmp, "x")
      File.mkdir_p!(outside)

      assert {:error, _} = Build.safe_rm_rf(elsewhere)
      assert {:error, _} = Build.safe_rm_rf(Path.join(plugins, "../x"))
      assert {:error, _} = Build.safe_rm_rf("/tmp/elsewhere")
      assert {:error, _} = Build.safe_rm_rf("")
      assert File.dir?(elsewhere)
      assert File.dir?(outside)
    end

    test "refuses a sibling whose name starts with the plugins dir name", %{
      plugins: plugins
    } do
      sibling = plugins <> "-other"
      File.mkdir_p!(sibling)
      assert {:error, _} = Build.safe_rm_rf(sibling)
      assert File.dir?(sibling)
    end

    test "refuses a symlink inside the plugins dir, outside folder survives", %{
      tmp: tmp,
      plugins: plugins
    } do
      outside = Path.join(tmp, "outside")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "precious"), "1")
      File.ln_s!(outside, Path.join(plugins, "link"))

      assert {:error, _} = Build.safe_rm_rf(Path.join(plugins, "link"))
      assert File.regular?(Path.join(outside, "precious"))
    end

    test "refuses a path through a symlinked component", %{tmp: tmp, plugins: plugins} do
      outside = Path.join(tmp, "outside2")
      File.mkdir_p!(Path.join(outside, "inner"))
      File.ln_s!(outside, Path.join(plugins, "link"))

      assert {:error, _} = Build.safe_rm_rf(Path.join(plugins, "link/inner"))
      assert File.dir?(Path.join(outside, "inner"))
    end

    test "works when the plugins dir itself is reached through a symlink", %{
      tmp: tmp,
      plugins: plugins
    } do
      alias_dir = Path.join(tmp, "alias")
      File.ln_s!(plugins, alias_dir)
      Application.put_env(:beamdash, :plugins_dir, alias_dir)
      File.mkdir_p!(Path.join(plugins, "y"))

      assert Build.safe_rm_rf(Path.join(alias_dir, "y")) == :ok
      refute File.exists?(Path.join(plugins, "y"))
      assert {:error, _} = Build.safe_rm_rf(alias_dir)
      assert {:error, _} = Build.safe_rm_rf(plugins)
    end
  end
end
