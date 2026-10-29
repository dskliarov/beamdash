defmodule Beamdash.NotebookStoreTest do
  use ExUnit.Case, async: true
  alias Beamdash.NotebookStore

  setup do
    dir = Path.join(System.tmp_dir!(), "beamdash-notebooks-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "saves, lists, opens and updates notebooks without overwriting external edits", %{dir: dir} do
    assert {:ok, version} = NotebookStore.save("demo.livemd", "# Demo\n", :new, dir)
    assert {:ok, ["demo.livemd"]} = NotebookStore.list(dir)
    assert {:ok, "# Demo\n", ^version} = NotebookStore.load("demo.livemd", dir)
    assert {:error, _} = NotebookStore.save("demo.livemd", "# Other", :new, dir)
    assert {:ok, next} = NotebookStore.save("demo.livemd", "# Edited\n", version, dir)
    assert next != version
    File.write!(Path.join(dir, "demo.livemd"), "# External\n")
    assert {:error, _} = NotebookStore.save("demo.livemd", "# Lost", next, dir)
    assert File.read!(Path.join(dir, "demo.livemd")) == "# External\n"
  end

  test "rejects traversal paths and symlinks", %{dir: dir} do
    assert {:error, _} = NotebookStore.save("../escape.livemd", "# Bad", :new, dir)
    File.write!(Path.join(dir, "actual.txt"), "important")
    File.ln_s!(Path.join(dir, "actual.txt"), Path.join(dir, "link.livemd"))
    assert {:error, _} = NotebookStore.load("link.livemd", dir)
    assert {:error, _} = NotebookStore.save("link.livemd", "# Bad", :new, dir)
    assert File.read!(Path.join(dir, "actual.txt")) == "important"
  end
end
