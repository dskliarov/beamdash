defmodule Beamdash.PluginsTest do
  # Beamdash.Plugins, the registry. Each test runs a named instance on its own
  # plugins dir (also set as :plugins_dir, which Build.safe_rm_rf guards on).
  # async: false because it compiles and loads the fixture into the VM.
  use ExUnit.Case, async: false

  alias Beamdash.{Plugins, Target}
  alias Beamdash.Plugins.{Build, Compat}
  alias Beamdash.Test.Fixture
  import Beamdash.Test.PluginFixture, only: [start_app: 2, stop_app: 1]

  @moduletag :capture_log

  @fixture Path.expand("../fixtures/plugins/hello_plugin", __DIR__)
  @hello [HelloPlugin, HelloPlugin.HelloLive]
  @impl_mods [
    HelloPlugin.Foo,
    Enumerable.HelloPlugin.Foo,
    HelloPlugin.Extra,
    HelloPlugin.Slow,
    HelloPlugin.Outside
  ]

  # compiled and loaded at runtime
  @compile {:no_warn_undefined, @hello ++ @impl_mods}

  setup do
    base = Path.join(System.tmp_dir!(), "beamdash_plugins_#{System.unique_integer([:positive])}")
    dir = Path.join(base, "plugins")
    File.mkdir_p!(dir)

    old =
      for key <- [:plugins_dir, :plugins_allow_local_git],
          do: {key, Application.fetch_env(:beamdash, key)}

    Application.put_env(:beamdash, :plugins_dir, dir)

    on_exit(fn ->
      Build.unload(@hello ++ @impl_mods)

      for {key, res} <- old do
        case res do
          {:ok, v} -> Application.put_env(:beamdash, key, v)
          :error -> Application.delete_env(:beamdash, key)
        end
      end

      File.rm_rf(base)
    end)

    %{base: base, dir: dir}
  end

  defp start_target do
    id = System.unique_integer([:positive])
    start_supervised!({Target, name: :"plugins_target_#{id}"}, id: :"target_#{id}")
  end

  defp start_plugins(dir, opts \\ []) do
    id = System.unique_integer([:positive])
    target = Keyword.get_lazy(opts, :target, &start_target/0)
    opts = Keyword.merge([name: :"plugins_#{id}", dir: dir, target: target], opts)
    start_supervised!({Plugins, opts}, id: :"plugins_#{id}")
  end

  defp copy_fixture(base, name \\ "hello") do
    src = Path.join(base, name)
    File.mkdir_p!(src)
    File.cp_r!(@fixture, src)
    src
  end

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

  defp make_repo(base) do
    repo = copy_fixture(base, "repo")
    git!(repo, ["init", "-q"])
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "init"])
    git!(repo, ["tag", "0.1.0"])
    repo
  end

  defp install!(server, text) do
    {:ok, ref} = Plugins.install(server, text)
    assert_receive {:beamdash_plugins, {:installed, ^ref, _app}}, 30_000
  end

  defp install_error(server, text) do
    {:ok, ref} = Plugins.install(server, text)
    assert_receive {:beamdash_plugins, {:install_failed, ^ref, msg}}, 30_000
    msg
  end

  defp entry(server, app), do: Enum.find(Plugins.list(server), &(&1.app == app))

  defp listing(dir) do
    for file <- Path.wildcard(Path.join(dir, "**/*"), match_dot: true),
        File.regular?(file),
        into: %{},
        do: {Path.relative_to(file, dir), File.read!(file)}
  end

  defp render_hello do
    %{__changed__: nil, node: nil, remote: nil, syntax: :erlang, count: 0}
    |> HelloPlugin.HelloLive.render()
    |> Phoenix.LiveViewTest.rendered_to_string()
  end

  defp saved(dir), do: dir |> Path.join("plugins.json") |> File.read!() |> Jason.decode!()

  defp write_saved(dir, json),
    do: File.write!(Path.join(dir, "plugins.json"), Jason.encode!(json))

  # Stops `server` and unloads the fixture, as after a restart of beamdash.
  defp stop!(server) do
    stop_supervised!(server |> Process.info(:registered_name) |> elem(1))
    Build.unload(@hello ++ @impl_mods)
  end

  defp eventually(fun, tries \\ 100) do
    if fun.() or tries == 0,
      do: assert(fun.()),
      else:
        (
          Process.sleep(50)
          eventually(fun, tries - 1)
        )
  end

  defp flush_changed do
    receive do
      {:beamdash_plugins, :changed} -> flush_changed()
    after
      0 -> :ok
    end
  end

  # A module whose beam (Elixir.Enumerable.HelloPlugin.Foo) sorts first in ebin.
  defp add_defimpl(src) do
    File.write!(Path.join(src, "lib/hello_plugin/foo.ex"), """
    defmodule HelloPlugin.Foo do
      defstruct []
    end

    defimpl Enumerable, for: HelloPlugin.Foo do
      def count(_), do: {:ok, 0}
      def member?(_, _), do: {:ok, false}
      def slice(_), do: {:error, __MODULE__}
      def reduce(_, {:halt, acc}, _), do: {:halted, acc}
      def reduce(_, {:cont, acc}, _), do: {:done, acc}
      def reduce(s, {:suspend, acc}, f), do: {:suspended, acc, &reduce(s, &1, f)}
    end
    """)
  end

  # HelloPlugin.Extra compiles at once; HelloPlugin.Slow takes `ms` to compile.
  defp add_slow(src, ms) do
    File.write!(Path.join(src, "lib/hello_plugin/extra.ex"), """
    defmodule HelloPlugin.Extra do
      def x, do: 1
    end
    """)

    File.write!(Path.join(src, "lib/hello_plugin/slow.ex"), """
    defmodule HelloPlugin.Slow do
      Process.sleep(#{ms})
      def y, do: 2
    end
    """)
  end

  defp loaded?(module), do: match?({:file, _}, :code.is_loaded(module))

  # Holds the rebuild of `app` open: a process that took the rebuild slot and
  # waits. Returns its pid.
  defp hold_rebuild(server, app) do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:held, GenServer.call(server, {:rebuild_info, app})})
        Process.sleep(:infinity)
      end)

    assert_receive {:held, {:ok, _entry, _dir}}
    pid
  end

  # A plugins dir whose plugins.json can't be written: its temp file is a folder.
  defp break_save(dir), do: File.mkdir_p!(Path.join(dir, "plugins.json.tmp"))

  describe "install" do
    test "a path plugin: steps in order, loaded, saved", %{base: base, dir: dir} do
      src = copy_fixture(base)
      server = start_plugins(dir)

      {:ok, ref} = Plugins.install(server, ~s|{:hello_plugin, path: "#{src}"}|)

      for step <- [:checking, :fetching, :compiling, :loading],
          do: assert_receive({:beamdash_plugins, {:install, ^ref, ^step}}, 30_000)

      assert_receive {:beamdash_plugins, {:installed, ^ref, :hello_plugin}}, 30_000

      assert %{source: :path, resolved: ^src, plugin: %{name: "Hello"}, status: :waiting} =
               plugin = entry(server, :hello_plugin)

      assert plugin.supports == [{:hello_app, "~> 1.0"}]
      assert Enum.sort(plugin.modules) == @hello
      assert HelloPlugin.__beamdash_plugin__().name == "Hello"

      assert [%{"app" => "hello_plugin", "source" => "path", "resolved" => ^src} = json] =
               saved(dir)

      assert json["supports"] == [%{"app" => "hello_app", "requirement" => "~> 1.0"}]
      assert json["spec"] =~ "hello_plugin"
      assert is_binary(json["installed_at"])
      # the source folder was used in place: only ebin is in the install dir
      assert File.ls!(Path.join(dir, "hello_plugin")) == ["ebin"]
    end

    test "from git: loaded, resolved is the commit", %{base: base, dir: dir} do
      Application.put_env(:beamdash, :plugins_allow_local_git, true)
      repo = make_repo(base)
      server = start_plugins(dir)

      install!(server, ~s|{:hello_plugin, git: "#{repo}", tag: "0.1.0"}|)

      commit = String.trim(git!(repo, ["rev-parse", "HEAD"]))
      assert %{source: :git, resolved: ^commit} = entry(server, :hello_plugin)
      assert HelloPlugin.__beamdash_plugin__().name == "Hello"
      assert File.dir?(Path.join([dir, "hello_plugin", "src"]))
    end

    test "a failing install (namespace clash) leaves nothing behind", %{base: base, dir: dir} do
      src = Path.join(base, "clash")
      File.mkdir_p!(Path.join(src, "lib"))

      File.write!(Path.join(src, "mix.exs"), """
      defmodule Clash.MixProject do
        use Mix.Project
        def project, do: [app: :clash, deps: [{:hello_app, "~> 1.0", runtime: false}]]
      end
      """)

      File.write!(Path.join(src, "lib/clash.ex"), """
      defmodule Beamdash.Format do
        def nope, do: :nope
      end
      """)

      md5 = Beamdash.Format.module_info(:md5)
      server = start_plugins(dir)

      msg = install_error(server, ~s|{:clash, path: "#{src}"}|)
      assert msg =~ "Beamdash.Format"
      assert Beamdash.Format.module_info(:md5) == md5
      assert Plugins.list(server) == []
      assert File.ls!(dir) -- ["plugins.json"] == []
    end

    test "a prefix whose namespace beamdash already uses is refused", %{base: base, dir: dir} do
      src = Path.join(base, "bd")
      File.mkdir_p!(Path.join(src, "lib"))

      File.write!(Path.join(src, "mix.exs"), """
      defmodule Bd.MixProject do
        use Mix.Project
        def project, do: [app: :bd, deps: [{:hello_app, "~> 1.0", runtime: false}]]
      end
      """)

      File.write!(Path.join(src, "lib/bd.ex"), """
      defmodule Beamdash do
        use Beamdash.Plugin, name: "Bd", pages: [{"p", "P", Beamdash.MyPage}]
      end

      defmodule Beamdash.MyPage do
        use Beamdash.Plugin.Page
        def render(assigns), do: ~H"x"
      end
      """)

      server = start_plugins(dir)
      msg = install_error(server, ~s|{:bd, path: "#{src}"}|)
      assert msg =~ "Beamdash"
      assert msg =~ "already"
      assert Plugins.list(server) == []
      assert function_exported?(Beamdash.Plugins, :list, 1)
    end

    test "the same app twice is refused", %{base: base, dir: dir} do
      src = copy_fixture(base)
      server = start_plugins(dir)
      install!(server, ~s|{:hello_plugin, path: "#{src}"}|)

      assert install_error(server, ~s|{:hello_plugin, path: "#{src}"}|) =~ "already installed"
      assert [_] = Plugins.list(server)
      assert HelloPlugin.__beamdash_plugin__().name == "Hello"
    end

    test "one install at a time", %{base: base, dir: dir} do
      src = copy_fixture(base)
      server = start_plugins(dir)

      {:ok, ref} = Plugins.install(server, ~s|{:hello_plugin, path: "#{src}"}|)

      assert {:error, "another plugin is being installed"} =
               Plugins.install(server, "{:x, path: \"/x\"}")

      assert_receive {:beamdash_plugins, {:installed, ^ref, :hello_plugin}}, 30_000
    end

    test "a crashed install task fails the install and frees the slot", %{base: base, dir: dir} do
      src = copy_fixture(base)
      server = start_plugins(dir)

      {:ok, ref} = Plugins.install(server, ~s|{:hello_plugin, path: "#{src}"}|)
      assert_receive {:beamdash_plugins, {:install, ^ref, :checking}}, 30_000
      %{installing: %{pid: pid, tmp: tmp}} = :sys.get_state(server)
      Process.exit(pid, :kill)

      assert_receive {:beamdash_plugins, {:install_failed, ^ref, msg}}, 5_000
      assert msg =~ "install crashed"
      refute File.exists?(tmp)
      assert Plugins.list(server) == []

      Build.unload(@hello)
      install!(server, ~s|{:hello_plugin, path: "#{src}"}|)
      assert [%{app: :hello_plugin}] = Plugins.list(server)
    end

    test "a plugins.json that can't be saved fails the install", %{base: base, dir: dir} do
      src = copy_fixture(base)
      server = start_plugins(dir)
      break_save(dir)

      msg = install_error(server, ~s|{:hello_plugin, path: "#{src}"}|)
      assert msg =~ "plugins.json"
      assert Plugins.list(server) == []
      assert :code.is_loaded(HelloPlugin) == false
      refute File.exists?(Path.join(dir, "hello_plugin"))
    end

    test "bad dependency text fails the install with the parse error", %{dir: dir} do
      server = start_plugins(dir)
      {:error, parse_error} = Beamdash.Plugins.Spec.parse("not a dep")
      assert install_error(server, "not a dep") == parse_error
    end
  end

  describe "remove" do
    test "a git plugin: its folder goes, modules are purged", %{base: base, dir: dir} do
      Application.put_env(:beamdash, :plugins_allow_local_git, true)
      repo = make_repo(base)
      server = start_plugins(dir)
      install!(server, ~s|{:hello_plugin, git: "#{repo}", tag: "0.1.0"}|)
      Phoenix.PubSub.subscribe(Beamdash.PubSub, "plugins")

      assert :ok = Plugins.remove(server, :hello_plugin)

      refute File.exists?(Path.join(dir, "hello_plugin"))
      assert :code.is_loaded(HelloPlugin) == false
      assert Plugins.list(server) == []
      assert saved(dir) == []
      assert_receive {:beamdash_plugins, {:removed, :hello_plugin}}
    end

    test "a path plugin: the source folder is untouched", %{base: base, dir: dir} do
      src = copy_fixture(base)
      before = listing(src)
      server = start_plugins(dir)
      install!(server, ~s|{:hello_plugin, path: "#{src}"}|)

      assert :ok = Plugins.remove(server, :hello_plugin)

      refute File.exists?(Path.join(dir, "hello_plugin"))
      assert listing(src) == before
      assert :code.is_loaded(HelloPlugin.HelloLive) == false
    end

    test "an unknown plugin", %{dir: dir} do
      server = start_plugins(dir)
      assert {:error, _} = Plugins.remove(server, :nope)
    end

    test "a plugins.json that can't be saved: refused, still installed", %{base: base, dir: dir} do
      src = copy_fixture(base)
      server = start_plugins(dir)
      install!(server, ~s|{:hello_plugin, path: "#{src}"}|)
      break_save(dir)

      assert {:error, msg} = Plugins.remove(server, :hello_plugin)
      assert msg =~ "plugins.json"
      assert [%{app: :hello_plugin}] = Plugins.list(server)
      assert HelloPlugin.__beamdash_plugin__().name == "Hello"
      assert File.dir?(Path.join([dir, "hello_plugin", "ebin"]))
    end
  end

  describe "rebuild" do
    test "picks up an edit; a broken edit keeps the old code", %{base: base, dir: dir} do
      src = copy_fixture(base)
      server = start_plugins(dir)
      install!(server, ~s|{:hello_plugin, path: "#{src}"}|)
      assert render_hello() =~ "Hello from nowhere"

      live = Path.join(src, "lib/hello_plugin/hello_live.ex")
      File.write!(live, String.replace(File.read!(live), "Hello from", "Howdy from"))

      assert :ok = Plugins.rebuild(server, :hello_plugin)
      assert render_hello() =~ "Howdy from nowhere"
      assert File.ls!(Path.join(dir, "hello_plugin")) == ["ebin"]

      File.write!(live, File.read!(live) <> "\ndefmodule Broken do\n")
      assert {:error, msg} = Plugins.rebuild(server, :hello_plugin)
      assert msg =~ "hello_live.ex"
      assert render_hello() =~ "Howdy from nowhere"
      assert %{status: :waiting} = entry(server, :hello_plugin)
      refute File.exists?(Path.join([dir, "hello_plugin", "ebin.new"]))
    end

    test "one rebuild at a time; remove and install wait for it", %{base: base, dir: dir} do
      src = copy_fixture(base)
      server = start_plugins(dir)
      install!(server, ~s|{:hello_plugin, path: "#{src}"}|)

      holder = hold_rebuild(server, :hello_plugin)

      assert {:error, msg} = Plugins.rebuild(server, :hello_plugin)
      assert msg =~ "being rebuilt"
      assert {:error, msg} = Plugins.remove(server, :hello_plugin)
      assert msg =~ "being rebuilt"
      assert install_error(server, ~s|{:hello_plugin, path: "#{src}"}|) =~ "hello_plugin"
      assert [%{app: :hello_plugin}] = Plugins.list(server)

      # the rebuilding caller died: the slot is free again
      Process.exit(holder, :kill)
      eventually(fn -> Plugins.rebuild(server, :hello_plugin) == :ok end)
      assert :ok = Plugins.remove(server, :hello_plugin)
      refute File.exists?(Path.join(dir, "hello_plugin"))
    end

    test "a caller that dies mid-compile leaves no new module loaded", %{base: base, dir: dir} do
      src = copy_fixture(base)
      server = start_plugins(dir)
      install!(server, ~s|{:hello_plugin, path: "#{src}"}|)
      add_slow(src, 1_500)

      caller = spawn(fn -> Plugins.rebuild(server, :hello_plugin) end)
      eventually(fn -> loaded?(HelloPlugin.Extra) end)
      Process.exit(caller, :kill)

      eventually(fn -> not Map.has_key?(:sys.get_state(server).rebuilding, :hello_plugin) end)
      refute loaded?(HelloPlugin.Extra)
      assert HelloPlugin.__beamdash_plugin__().name == "Hello"
      refute File.exists?(Path.join([dir, "hello_plugin", "ebin.new"]))

      # its compile workers are gone too: nothing else gets loaded later
      Process.sleep(1_700)
      refute loaded?(HelloPlugin.Slow)
      add_slow(src, 0)
      assert :ok = Plugins.rebuild(server, :hello_plugin)
      assert HelloPlugin.Extra.x() == 1
    end

    test "a failed rebuild frees the slot", %{base: base, dir: dir} do
      src = copy_fixture(base)
      server = start_plugins(dir)
      install!(server, ~s|{:hello_plugin, path: "#{src}"}|)
      live = Path.join(src, "lib/hello_plugin/hello_live.ex")
      good = File.read!(live)

      File.write!(live, good <> "\ndefmodule Broken do\n")
      assert {:error, _} = Plugins.rebuild(server, :hello_plugin)
      File.write!(live, good)
      assert :ok = Plugins.rebuild(server, :hello_plugin)
    end

    test "a swap whose load fails goes back to the old code", %{base: base, dir: dir} do
      src = copy_fixture(base)
      server = start_plugins(dir)
      install!(server, ~s|{:hello_plugin, path: "#{src}"}|)
      install_dir = Path.join(dir, "hello_plugin")

      {:ok, entry, ^install_dir} = GenServer.call(server, {:rebuild_info, :hello_plugin})
      # ebin.new has no beams, so loading it fails
      ebin_new = Path.join(install_dir, "ebin.new")
      File.mkdir_p!(ebin_new)

      built =
        Map.merge(Map.take(entry, [:plugin, :modules, :supports, :prefix]), %{ebin_new: ebin_new})

      assert {:error, _} =
               GenServer.call(server, {:rebuild_commit, :hello_plugin, {:ok, built}})

      assert %{status: :waiting, plugin: %{name: "Hello"}} = entry(server, :hello_plugin)
      assert HelloPlugin.__beamdash_plugin__().name == "Hello"
      assert File.ls!(install_dir) == ["ebin"]
    end

    test "a swap that can't load the old code back marks it failed", %{base: base, dir: dir} do
      src = copy_fixture(base)
      server = start_plugins(dir)
      install!(server, ~s|{:hello_plugin, path: "#{src}"}|)
      install_dir = Path.join(dir, "hello_plugin")

      {:ok, entry, _} = GenServer.call(server, {:rebuild_info, :hello_plugin})
      ebin_new = Path.join(install_dir, "ebin.new")
      File.mkdir_p!(ebin_new)
      File.rm!(Path.join([install_dir, "ebin", "Elixir.HelloPlugin.HelloLive.beam"]))

      built =
        Map.merge(Map.take(entry, [:plugin, :modules, :supports, :prefix]), %{ebin_new: ebin_new})

      assert {:error, _} =
               GenServer.call(server, {:rebuild_commit, :hello_plugin, {:ok, built}})

      assert %{status: {:failed, msg}, plugin: nil} = entry(server, :hello_plugin)
      assert msg =~ "HelloLive"
      assert Plugins.active(server) == []
    end

    test "a failed rebuild leaves a same-prefix module from elsewhere loaded",
         %{base: base, dir: dir} do
      src = copy_fixture(base)
      server = start_plugins(dir)
      install!(server, ~s|{:hello_plugin, path: "#{src}"}|)

      # HelloPlugin.Outside, loaded from a beam outside the plugin's folders
      [{mod, bin}] = Code.compile_string("defmodule HelloPlugin.Outside do def x, do: 1 end")
      Build.unload([mod])
      outside = Path.join(base, "outside")
      File.mkdir_p!(outside)
      beam = Path.join(outside, "Elixir.HelloPlugin.Outside.beam")
      File.write!(beam, bin)
      {:module, _} = :code.load_binary(mod, String.to_charlist(beam), bin)

      live = Path.join(src, "lib/hello_plugin/hello_live.ex")
      File.write!(live, File.read!(live) <> "\ndefmodule Broken do\n")
      assert {:error, _} = Plugins.rebuild(server, :hello_plugin)

      assert HelloPlugin.Outside.x() == 1
      assert HelloPlugin.__beamdash_plugin__().name == "Hello"
    end

    test "a plugins.json that can't be saved is reported", %{base: base, dir: dir} do
      src = copy_fixture(base)
      server = start_plugins(dir)
      install!(server, ~s|{:hello_plugin, path: "#{src}"}|)
      break_save(dir)

      assert {:error, msg} = Plugins.rebuild(server, :hello_plugin)
      assert msg =~ "plugins.json"
    end

    test "only path plugins", %{base: base, dir: dir} do
      Application.put_env(:beamdash, :plugins_allow_local_git, true)
      repo = make_repo(base)
      server = start_plugins(dir)
      install!(server, ~s|{:hello_plugin, git: "#{repo}", tag: "0.1.0"}|)

      assert {:error, msg} = Plugins.rebuild(server, :hello_plugin)
      assert msg =~ "path"
    end
  end

  describe "startup" do
    test "a good entry loads (built first), a broken one is failed", %{base: base, dir: dir} do
      src = copy_fixture(base)
      missing = Path.join(base, "gone")

      File.write!(
        Path.join(dir, "plugins.json"),
        Jason.encode!([
          %{
            "app" => "hello_plugin",
            "spec" => ~s|{:hello_plugin, path: "#{src}"}|,
            "source" => "path",
            "resolved" => src,
            "supports" => [%{"app" => "hello_app", "requirement" => "~> 1.0"}],
            "installed_at" => "2026-10-25T00:00:00Z"
          },
          %{
            "app" => "gone_plugin",
            "spec" => ~s|{:gone_plugin, path: "#{missing}"}|,
            "source" => "path",
            "resolved" => missing,
            "supports" => [%{"app" => "gone_app", "requirement" => nil}],
            "installed_at" => "2026-10-25T00:00:00Z"
          }
        ])
      )

      server = start_plugins(dir)

      eventually(fn -> entry(server, :hello_plugin).status == :waiting end)
      assert %{plugin: %{name: "Hello"}} = entry(server, :hello_plugin)
      assert HelloPlugin.__beamdash_plugin__().name == "Hello"
      eventually(fn -> match?({:failed, _}, entry(server, :gone_plugin).status) end)
      assert %{plugin: nil} = entry(server, :gone_plugin)
    end

    test "builds run in the background: the registry answers meanwhile", %{base: base, dir: dir} do
      src = copy_fixture(base)

      write_saved(dir, [
        %{
          "app" => "hello_plugin",
          "spec" => ~s|{:hello_plugin, path: "#{src}"}|,
          "source" => "path",
          "resolved" => src,
          "supports" => [%{"app" => "hello_app", "requirement" => "~> 1.0"}]
        }
      ])

      Phoenix.PubSub.subscribe(Beamdash.PubSub, "plugins")
      server = start_plugins(dir)

      assert %{status: :building, plugin: nil} = entry(server, :hello_plugin)
      assert Plugins.active(server) == []
      assert {:error, :building} = Plugins.page(server, "hello_plugin", "hello")
      assert {:error, msg} = Plugins.rebuild(server, :hello_plugin)
      assert msg =~ "being built"
      assert {:error, _} = Plugins.remove(server, :hello_plugin)

      eventually(fn -> entry(server, :hello_plugin).status == :waiting end)
      assert_received {:beamdash_plugins, :changed}
      assert [%{"prefix" => "HelloPlugin"}] = saved(dir)
    end

    test "a plugin with a defimpl survives a restart", %{base: base, dir: dir} do
      src = copy_fixture(base)
      add_defimpl(src)
      server = start_plugins(dir)
      install!(server, ~s|{:hello_plugin, path: "#{src}"}|)
      assert [%{"prefix" => "HelloPlugin"}] = saved(dir)

      stop!(server)
      server = start_plugins(dir)
      assert %{status: :waiting, plugin: %{name: "Hello"}} = entry(server, :hello_plugin)
      assert Enumerable.HelloPlugin.Foo in entry(server, :hello_plugin).modules

      # an entry saved before the prefix was: found from the beams
      stop!(server)
      write_saved(dir, Enum.map(saved(dir), &Map.delete(&1, "prefix")))
      server = start_plugins(dir)
      assert %{status: :waiting, plugin: %{name: "Hello"}} = entry(server, :hello_plugin)
    end

    test "a saved prefix of Beamdash or Elixir is not trusted", %{base: base, dir: dir} do
      src = copy_fixture(base)
      server = start_plugins(dir)
      install!(server, ~s|{:hello_plugin, path: "#{src}"}|)
      live = Path.join(src, "lib/hello_plugin/hello_live.ex")
      File.write!(live, File.read!(live) <> "\ndefmodule Broken do\n")

      Enum.reduce(["Beamdash", "BeamdashWeb", "Elixir"], server, fn prefix, server ->
        stop!(server)
        write_saved(dir, Enum.map(saved(dir), &Map.put(&1, "prefix", prefix)))
        md5 = Beamdash.Format.module_info(:md5)

        server = start_plugins(dir)
        eventually(fn -> entry(server, :hello_plugin).status == :waiting end)
        assert %{plugin: %{name: "Hello"}} = entry(server, :hello_plugin)
        # a failed rebuild unloads nothing of beamdash
        assert {:error, _} = Plugins.rebuild(server, :hello_plugin)
        assert Beamdash.Format.module_info(:md5) == md5
        assert function_exported?(Beamdash.Plugins, :list, 1)
        server
      end)
    end

    test "a broken newer source keeps the last good build", %{base: base, dir: dir} do
      src = copy_fixture(base)
      server = start_plugins(dir)
      install!(server, ~s|{:hello_plugin, path: "#{src}"}|)
      stop!(server)

      live = Path.join(src, "lib/hello_plugin/hello_live.ex")
      File.write!(live, File.read!(live) <> "\ndefmodule Broken do\n")
      File.touch!(live, System.os_time(:second) + 60)

      server = start_plugins(dir)
      eventually(fn -> entry(server, :hello_plugin).status == :waiting end)
      assert %{plugin: %{name: "Hello"}, build_error: msg} = entry(server, :hello_plugin)
      assert msg =~ "hello_live.ex"
      assert render_hello() =~ "Hello from nowhere"
      assert File.ls!(Path.join(dir, "hello_plugin")) == ["ebin"]
    end

    test "a git plugin without its ebin is rebuilt from src", %{base: base, dir: dir} do
      Application.put_env(:beamdash, :plugins_allow_local_git, true)
      repo = make_repo(base)
      server = start_plugins(dir)
      install!(server, ~s|{:hello_plugin, git: "#{repo}", tag: "0.1.0"}|)
      stop!(server)
      ebin = Path.join([dir, "hello_plugin", "ebin"])
      File.rm_rf!(ebin)

      server = start_plugins(dir)
      eventually(fn -> entry(server, :hello_plugin).status == :waiting end)
      assert %{plugin: %{name: "Hello"}, build_error: nil} = entry(server, :hello_plugin)
      assert List.to_string(:code.which(HelloPlugin)) =~ ebin
    end

    test "a swap cut short: a lone ebin.old is put back", %{base: base, dir: dir} do
      src = copy_fixture(base)
      server = start_plugins(dir)
      install!(server, ~s|{:hello_plugin, path: "#{src}"}|)
      stop!(server)
      install_dir = Path.join(dir, "hello_plugin")
      File.rename!(Path.join(install_dir, "ebin"), Path.join(install_dir, "ebin.old"))
      File.mkdir_p!(Path.join(install_dir, "ebin.new"))

      server = start_plugins(dir)
      assert %{status: :waiting, plugin: %{name: "Hello"}} = entry(server, :hello_plugin)
      assert File.ls!(install_dir) == ["ebin"]
    end

    test "a crashed startup build keeps the last good build", %{base: base, dir: dir} do
      src = copy_fixture(base)
      server = start_plugins(dir)
      install!(server, ~s|{:hello_plugin, path: "#{src}"}|)
      stop!(server)
      add_slow(src, 3_000)
      File.touch!(Path.join(src, "lib/hello_plugin/slow.ex"), System.os_time(:second) + 60)

      server = start_plugins(dir)
      %{startup: %{pid: pid}} = :sys.get_state(server)
      eventually(fn -> loaded?(HelloPlugin.Extra) end)
      Process.exit(pid, :kill)

      eventually(fn -> entry(server, :hello_plugin).status == :waiting end)
      assert %{plugin: %{name: "Hello"}, build_error: msg} = entry(server, :hello_plugin)
      assert msg =~ "crashed"
      refute loaded?(HelloPlugin.Extra)
      assert render_hello() =~ "Hello from nowhere"
      assert File.ls!(Path.join(dir, "hello_plugin")) == ["ebin"]
    end

    test "a startup build records the new supports", %{base: base, dir: dir} do
      src = copy_fixture(base)
      server = start_plugins(dir)
      install!(server, ~s|{:hello_plugin, path: "#{src}"}|)
      stop!(server)
      mix = Path.join(src, "mix.exs")

      File.write!(
        mix,
        String.replace(File.read!(mix), ~s|:hello_app, "~> 1.0"|, ~s|:hello_app, "~> 1.1"|)
      )

      File.touch!(mix, System.os_time(:second) + 60)

      server = start_plugins(dir)
      eventually(fn -> entry(server, :hello_plugin).status == :waiting end)
      assert entry(server, :hello_plugin).supports == [{:hello_app, "~> 1.1"}]
      assert [%{"supports" => [%{"requirement" => "~> 1.1"}]}] = saved(dir)
    end

    test "leftover install temp folders are deleted", %{dir: dir} do
      tmp = Path.join(dir, ".tmp-123")
      File.mkdir_p!(Path.join(tmp, "src"))
      server = start_plugins(dir)
      assert Plugins.list(server) == []
      refute File.exists?(tmp)
    end

    test "an installed plugin loads from its ebin", %{base: base, dir: dir} do
      src = copy_fixture(base)
      server = start_plugins(dir)
      install!(server, ~s|{:hello_plugin, path: "#{src}"}|)
      stop!(server)

      server = start_plugins(dir)

      assert %{status: :waiting} = entry(server, :hello_plugin)
      assert List.to_string(:code.which(HelloPlugin)) =~ Path.join(dir, "hello_plugin/ebin")
    end

    test "a missing or broken plugins.json is empty", %{dir: dir} do
      File.write!(Path.join(dir, "plugins.json"), "{not json")
      assert Plugins.list(start_plugins(dir)) == []
    end
  end

  describe "Compat.status/2" do
    test "versions" do
      assert Compat.status([{:a, "~> 1.0"}], [{:a, "1.2.0"}]) == :active

      assert Compat.status([{:a, "~> 1.0"}], [{:a, "2.0.0"}]) ==
               {:incompatible, :a, "2.0.0", "~> 1.0"}

      assert Compat.status([{:a, "~> 1.0"}], [{:a, "1.2"}]) == :active
      assert Compat.status([{:a, "~> 1.0"}], [{:a, "1"}]) == :active
      assert Compat.status([{:a, nil}], [{:a, "weird"}]) == :active
      # a leading "v", as some applications write their vsn
      assert Compat.status([{:a, "~> 0.11"}], [{:a, "v0.11.0"}]) == :active
      assert Compat.status([{:a, "~> 1.0"}], [{:a, "v1.2"}]) == :active
    end

    test "an invalid version doesn't match, and the reason says so" do
      status = Compat.status([{:a, "~> 1.0"}], [{:a, "weird"}])
      assert status == {:incompatible, :a, "weird", "~> 1.0"}
      assert Compat.reason(status) =~ "valid version"
      assert Compat.reason({:incompatible, :a, "2.0.0", "~> 1.0"}) =~ "a 2.0.0 is running"
    end

    test "nothing running is waiting; any match is active" do
      assert Compat.status([{:a, "~> 1.0"}], [{:other, "1.0.0"}]) == :waiting
      assert Compat.status([{:a, "~> 1.0"}], []) == :waiting

      assert Compat.status([{:a, "~> 1.0"}, {:b, "~> 2.0"}], [{:a, "3.0.0"}, {:b, "2.1.0"}]) ==
               :active

      assert Compat.status([{:a, "~> 1.0"}, {:b, "~> 2.0"}], [{:b, "3.0.0"}, {:a, "3.0.0"}]) ==
               {:incompatible, :a, "3.0.0", "~> 1.0"}
    end
  end

  describe "active set" do
    test "follows the node's running applications", %{base: base, dir: dir} do
      {peer, node} = Fixture.start_peer()
      on_exit(fn -> Fixture.stop_peer(peer) end)
      target = start_target()
      {:ok, _} = Target.connect(Atom.to_string(node), Fixture.cookie(), target)

      src = copy_fixture(base)
      Phoenix.PubSub.subscribe(Beamdash.PubSub, "plugins")
      server = start_plugins(dir, target: target, refresh_ms: 100)
      install!(server, ~s|{:hello_plugin, path: "#{src}"}|)
      assert entry(server, :hello_plugin).status == :waiting

      # each change of the active set is broadcast
      flush_changed()
      start_app(node, "1.2.0")
      assert_receive {:beamdash_plugins, :changed}, 2_000
      assert entry(server, :hello_plugin).status == :active

      assert [%{app: :hello_plugin, name: "Hello", pages: [%{slug: "hello"}]}] =
               Plugins.active(server)

      assert {:ok, %{app: :hello_plugin, page: %{module: HelloPlugin.HelloLive}}} =
               Plugins.page(server, "hello_plugin", "hello")

      assert {:error, :not_found} = Plugins.page(server, "hello_plugin", "nope")
      assert {:error, :not_found} = Plugins.page(server, "nope", "hello")

      flush_changed()
      stop_app(node)
      assert_receive {:beamdash_plugins, :changed}, 2_000
      assert entry(server, :hello_plugin).status == :waiting
      assert Plugins.active(server) == []
      assert {:error, :waiting} = Plugins.page(server, "hello_plugin", "hello")

      start_app(node, "2.0.0")
      incompatible = {:incompatible, :hello_app, "2.0.0", "~> 1.0"}
      eventually(fn -> entry(server, :hello_plugin).status == incompatible end)
      assert Plugins.active(server) == []
      assert {:error, ^incompatible} = Plugins.page(server, "hello_plugin", "hello")

      flush_changed()
      :ok = Target.disconnect(target)
      assert_receive {:beamdash_plugins, :changed}, 2_000
      assert entry(server, :hello_plugin).status == :waiting
    end
  end
end
