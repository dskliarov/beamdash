defmodule Beamdash.LocalSourceTest do
  use ExUnit.Case, async: true

  alias Beamdash.LocalSource

  setup do
    root =
      Path.join(System.tmp_dir!(), "beamdash_local_src_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp touch(path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")
    path
  end

  # a node where `mod` belongs to `app` and was compiled from `source`
  defp node_with(app, source) do
    fn
      :n@h, :application, :get_application, [_mod] ->
        if app, do: {:ok, {:ok, app}}, else: {:ok, :undefined}

      :n@h, _mod, :module_info, [:compile] ->
        {:ok, if(source, do: [source: String.to_charlist(source)], else: [])}
    end
  end

  test "matches the tail of the compile path under the app's folder", %{root: root} do
    file = touch(Path.join(root, "my_app/apps/my_app/src/my_mod.erl"))
    rpc = node_with(:my_app, "/build/apps/my_app/src/my_mod.erl")

    assert {:ok, ^file} =
             LocalSource.find(:n@h, :my_mod, %{"my_app" => Path.join(root, "my_app")}, rpc)
  end

  test "falls back to the file name, outside _build and deps first, shortest", %{root: root} do
    dir = Path.join(root, "proj")
    touch(Path.join(dir, "_build/default/lib/my_app/src/my_mod.erl"))
    touch(Path.join(dir, "deps/x/src/my_mod.erl"))
    own = touch(Path.join(dir, "src/my_mod.erl"))
    touch(Path.join(dir, "test/support/deep/my_mod.erl"))
    rpc = node_with(:my_app, "/elsewhere/entirely/my_mod.erl")

    assert {:ok, ^own} = LocalSource.find(:n@h, :my_mod, %{"my_app" => dir}, rpc)
  end

  test "an Erlang module without a compile path is looked for as <mod>.erl", %{root: root} do
    file = touch(Path.join(root, "src/my_mod.erl"))
    assert {:ok, ^file} = LocalSource.find(:n@h, :my_mod, %{"a" => root}, node_with(:a, nil))
  end

  test "an Elixir module's file is found from its compile path", %{root: root} do
    file = touch(Path.join(root, "lib/my_app/worker.ex"))
    rpc = node_with(:my_app, "/app/lib/my_app/worker.ex")

    assert {:ok, ^file} = LocalSource.find(:n@h, MyApp.Worker, %{"my_app" => root}, rpc)
  end

  test "other configured folders are searched if the application folder has no match", %{
    root: root
  } do
    file = touch(Path.join(root, "other/src/my_mod.erl"))
    mine = Path.join(root, "mine")
    File.mkdir_p!(mine)
    dirs = %{"my_app" => mine, "other" => Path.join(root, "other")}

    assert {:ok, ^file} = LocalSource.find(:n@h, :my_mod, dirs, node_with(:my_app, nil))
  end

  test "every folder is searched when the application has none set", %{root: root} do
    file = touch(Path.join(root, "other/src/my_mod.erl"))
    dirs = %{"other" => Path.join(root, "other")}

    assert {:ok, ^file} = LocalSource.find(:n@h, :my_mod, dirs, node_with(nil, nil))
    assert {:ok, ^file} = LocalSource.find(:n@h, :my_mod, dirs, node_with(:unset_app, nil))
  end

  test "no folders, no file" do
    rpc = fn _, _, _, _ -> flunk("the node is not asked") end
    assert :error = LocalSource.find(:n@h, :my_mod, %{}, rpc)
  end

  test "a node that can't be asked still allows a search by module name", %{root: root} do
    file = touch(Path.join(root, "src/my_mod.erl"))
    rpc = fn _, _, _, _ -> {:error, {:erpc, :noconnection}} end
    assert {:ok, ^file} = LocalSource.find(:n@h, :my_mod, %{"a" => root}, rpc)
  end

  test "the owning application's folder takes precedence over other entries", %{root: root} do
    other = Path.join(root, "other")
    mine = Path.join(root, "mine")
    touch(Path.join(other, "src/my_mod.erl"))
    file = touch(Path.join(mine, "src/my_mod.erl"))

    assert {:ok, ^file} =
             LocalSource.find(
               :n@h,
               :my_mod,
               %{"aaa_other" => other, "my_app" => mine},
               node_with(:my_app, nil)
             )
  end

  test "finds Elixir source across configured folders without a compile path", %{root: root} do
    file = touch(Path.join(root, "other/lib/my_app/worker.ex"))

    assert {:ok, ^file} =
             LocalSource.find(
               :n@h,
               MyApp.Worker,
               %{"my_app" => Path.join(root, "missing"), "other" => Path.join(root, "other")},
               node_with(:my_app, nil)
             )
  end

  test "finds VNode by its declaration when its file is vnode.ex and compile path is stale", %{
    root: root
  } do
    path = touch(Path.join(root, "apps/pace_keeper_core/lib/pace_keeper_core/vnode.ex"))
    File.write!(path, "defmodule PaceKeeperCore.VNode do\nend\n")

    assert {:ok, ^path} =
             LocalSource.find(
               :n@h,
               PaceKeeperCore.VNode,
               %{"pace_keeper" => root},
               node_with(:pace_keeper_core, "/removed/generated.ex")
             )
  end

  test "finds modules in differently named files without matching comments", %{root: root} do
    comment = touch(Path.join(root, "lib/comment.ex"))
    File.write!(comment, "# defmodule PaceKeeperCore.Console do\ndefmodule Unrelated do end")
    path = touch(Path.join(root, "lib/admin.ex"))

    File.write!(
      path,
      "defmodule PaceKeeperCore.Console do end\ndefmodule PaceKeeperCore.Supervisor do end"
    )

    for mod <- [PaceKeeperCore.Console, PaceKeeperCore.Supervisor] do
      assert {:ok, ^path} =
               LocalSource.find(
                 :n@h,
                 mod,
                 %{"pace_keeper" => root},
                 node_with(:pace_keeper_core, nil)
               )
    end
  end

  test "finds the Mix project for a source path and prefers its umbrella root", %{root: root} do
    source = touch(Path.join(root, "project/lib/worker.ex"))
    project = Path.join(root, "project")
    touch(Path.join(project, "mix.exs"))
    assert LocalSource.project_dir(source) == project
    child = Path.join(project, "apps/core")
    touch(Path.join(child, "mix.exs"))
    source = touch(Path.join(child, "lib/worker.ex"))
    assert LocalSource.project_dir(source) == project
    assert LocalSource.project_dir(Path.join(root, "missing.ex")) == nil
    assert LocalSource.project_dir(touch(Path.join(root, "loose.ex"))) == nil
  end

  test "searches declarations recursively inside deps and build subfolders", %{root: root} do
    for folder <- ["deps/vendor/nested/lib", "_build/dev/generated/lib"] do
      path = touch(Path.join(root, folder <> "/unusual.ex"))
      File.write!(path, "defmodule Dependency.Deep.Worker do end")

      assert {:ok, ^path} =
               LocalSource.find(
                 :n@h,
                 Dependency.Deep.Worker,
                 %{"app" => root},
                 node_with(:app, nil)
               )

      File.rm!(path)
    end
  end

  test "prefers project declarations over shorter dependency matches", %{root: root} do
    dep = touch(Path.join(root, "deps/a/x.ex"))
    own = touch(Path.join(root, "apps/my_application/lib/deeply/nested/implementation.ex"))
    for path <- [dep, own], do: File.write!(path, "defmodule Matching.Worker do end")

    assert {:ok, ^own} =
             LocalSource.find(:n@h, Matching.Worker, %{"app" => root}, node_with(:app, nil))
  end

  test "follows linked dependencies without looping back through their parents", %{root: root} do
    shared = Path.join(root, "shared")
    path = touch(Path.join(shared, "nested/arbitrary.ex"))
    File.write!(path, "defmodule Linked.Worker do end")
    project = Path.join(root, "project")
    File.mkdir_p!(Path.join(project, "deps"))
    File.ln_s!(shared, Path.join(project, "deps/linked"))
    File.ln_s!(project, Path.join(shared, "parent_loop"))

    assert {:ok, found} =
             LocalSource.find(:n@h, Linked.Worker, %{"app" => project}, node_with(:app, nil))

    assert File.read!(found) == File.read!(path)
  end
end
