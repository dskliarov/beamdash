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

  test "an abandoned lock file does not prevent saving", %{dir: dir} do
    File.write!(Path.join(dir, "demo.livemd.lock"), "abandoned")
    assert {:ok, _} = NotebookStore.save("demo.livemd", "# Recovered", :new, dir)
    assert File.read!(Path.join(dir, "demo.livemd")) == "# Recovered"
  end

  test "a live process holding the socket lock prevents saving", %{dir: dir} do
    {:ok, stat} = File.stat(dir)
    key = {stat.major_device, stat.minor_device, stat.inode, "demo.livemd.lock"}
    <<hash::unsigned-16, _::binary>> = :crypto.hash(:sha256, :erlang.term_to_binary(key))
    port = 1024 + rem(hash, 64_512)

    {:ok, socket} =
      :gen_tcp.listen(port, [:binary, active: false, reuseaddr: false, ip: {127, 0, 0, 1}])

    assert {:error, _} = NotebookStore.save("demo.livemd", "# Blocked", :new, dir)
    :ok = :gen_tcp.close(socket)
    assert {:ok, _} = NotebookStore.save("demo.livemd", "# Allowed", :new, dir)
  end
end
