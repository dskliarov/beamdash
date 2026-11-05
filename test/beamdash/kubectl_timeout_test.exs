defmodule Beamdash.KubectlTimeoutTest do
  use ExUnit.Case, async: false

  alias Beamdash.Kubectl

  setup do
    dir =
      Path.join(System.tmp_dir!(), "beamdash-hung-kubectl-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    pid_file = Path.join(dir, "pid")
    File.write!(Path.join(dir, "kubectl"), "#!/bin/sh\necho $$ > #{pid_file}\nexec sleep 10\n")
    File.chmod!(Path.join(dir, "kubectl"), 0o755)

    path = System.get_env("PATH")
    System.put_env("PATH", dir <> ":" <> path)

    on_exit(fn ->
      System.put_env("PATH", path)
      File.rm_rf!(dir)
    end)

    %{pid_file: pid_file}
  end

  test "a kubectl that never answers is given up on and its process is killed", ctx do
    assert {message, 124} = Kubectl.run_kubectl(["get", "pods"], 5_000)
    assert message =~ "did not answer"

    assert wait_file(ctx.pid_file, 40), "kubectl never started"
    pid = ctx.pid_file |> File.read!() |> String.trim()
    assert wait_gone(pid, 40), "kubectl process #{pid} is still running"
  end

  defp wait_file(_path, 0), do: false

  defp wait_file(path, tries) do
    if File.exists?(path) do
      true
    else
      Process.sleep(50)
      wait_file(path, tries - 1)
    end
  end

  defp wait_gone(_pid, 0), do: false

  defp wait_gone(pid, tries) do
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_, 0} ->
        Process.sleep(50)
        wait_gone(pid, tries - 1)

      _ ->
        true
    end
  end
end
