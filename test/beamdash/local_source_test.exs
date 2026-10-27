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

  test "only the module's application's folder is searched when it has one", %{root: root} do
    touch(Path.join(root, "other/src/my_mod.erl"))
    mine = Path.join(root, "mine")
    File.mkdir_p!(mine)
    dirs = %{"my_app" => mine, "other" => Path.join(root, "other")}

    assert :error = LocalSource.find(:n@h, :my_mod, dirs, node_with(:my_app, nil))
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
end
