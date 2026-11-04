defmodule Beamdash.KubectlTimeoutTest do
  use ExUnit.Case, async: false

  alias Beamdash.Kubectl

  setup do
    dir =
      Path.join(System.tmp_dir!(), "beamdash-hung-kubectl-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "kubectl"), "#!/bin/sh\nsleep 10\n")
    File.chmod!(Path.join(dir, "kubectl"), 0o755)

    path = System.get_env("PATH")
    System.put_env("PATH", dir <> ":" <> path)

    on_exit(fn ->
      System.put_env("PATH", path)
      File.rm_rf!(dir)
    end)
  end

  test "a kubectl that never answers is given up on, not waited for" do
    assert {message, 124} = Kubectl.run_kubectl(["get", "pods"], 200)
    assert message =~ "did not answer"
  end
end
