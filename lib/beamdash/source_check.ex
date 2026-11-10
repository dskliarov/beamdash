defmodule Beamdash.SourceCheck do
  @moduledoc """
  Whether an application's source folder on this computer is the code the
  node runs. A release built from git carries its commit in the version, as
  in `3.8.4+build.7869.ref3be90c014`.
  """

  @doc """
  The status of the checkout in `folder` against the version `vsn`:

    * `no_folder`: no existing folder is configured for the application
    * `no_git`: the folder is not in a git checkout
    * `no_ref`: the version names no commit
    * `mismatch`: the checkout's HEAD is not the commit the version names
    * `dirty`: the folder has uncommitted changes (`changed` counts them)
    * `match`: the checkout is the built commit, with no changes

  `git` takes git's arguments and the folder, and returns `{:ok, output}` or
  `:error`.
  """
  def check(vsn, folder, git \\ &git/2) do
    if is_binary(folder) and File.dir?(folder),
      do: check_git(vsn, folder, git),
      else: %{status: "no_folder"}
  end

  defp check_git(vsn, folder, git) do
    case git.(["rev-parse", "HEAD"], folder) do
      {:ok, out} -> compare(ref(vsn), String.trim(out), folder, git)
      :error -> %{status: "no_git"}
    end
  end

  defp compare(nil, head, _folder, _git), do: %{status: "no_ref", head: head}

  defp compare(ref, head, folder, git) do
    if String.starts_with?(head, ref) do
      case changed(folder, git) do
        {:ok, 0} -> %{status: "match", ref: ref, head: head, changed: 0}
        {:ok, n} -> %{status: "dirty", ref: ref, head: head, changed: n}
        :error -> %{status: "no_git"}
      end
    else
      %{status: "mismatch", ref: ref, head: head}
    end
  end

  defp changed(folder, git) do
    case git.(["status", "--porcelain", "--", "."], folder) do
      {:ok, out} -> {:ok, out |> String.split("\n", trim: true) |> length()}
      :error -> :error
    end
  end

  defp ref(vsn) when is_binary(vsn) do
    case Regex.run(~r/\.ref([0-9a-f]{6,40})/, vsn) do
      [_, ref] -> ref
      nil -> nil
    end
  end

  defp ref(_vsn), do: nil

  defp git(args, folder) do
    with exe when is_binary(exe) <- System.find_executable("git"),
         {out, 0} <- System.cmd(exe, args, cd: folder, stderr_to_stdout: true) do
      {:ok, out}
    else
      _ -> :error
    end
  end
end
