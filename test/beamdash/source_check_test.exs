defmodule Beamdash.SourceCheckTest do
  use ExUnit.Case, async: true

  alias Beamdash.SourceCheck

  @head "3be90c014aa5c1f0e2d7b8c9a6f4e3d2c1b0a998"
  @vsn "3.8.4+build.7869.ref3be90c014"

  defp runner(head, status \\ "") do
    fn
      ["rev-parse", "HEAD"], _folder when is_binary(head) -> {:ok, head <> "\n"}
      ["rev-parse", "HEAD"], _folder -> :error
      ["status" | _], _folder -> {:ok, status}
    end
  end

  test "no folder is reported when none is configured or it does not exist" do
    assert %{status: "no_folder"} = SourceCheck.check(@vsn, nil, runner(@head))

    missing = Path.join(System.tmp_dir!(), "no_such_source_#{System.unique_integer([:positive])}")
    assert %{status: "no_folder"} = SourceCheck.check(@vsn, missing, runner(@head))
  end

  test "a folder that is not a git checkout is reported" do
    assert %{status: "no_git"} = SourceCheck.check(@vsn, System.tmp_dir!(), runner(nil))
  end

  test "a version without a commit is reported" do
    assert %{status: "no_ref", head: @head} =
             SourceCheck.check("1.0.0", System.tmp_dir!(), runner(@head))
  end

  test "a checkout at another commit is a mismatch" do
    other = "0123456789abcdef0123456789abcdef01234567"

    assert %{status: "mismatch", ref: "3be90c014"} =
             SourceCheck.check(@vsn, System.tmp_dir!(), runner(other))
  end

  test "a checkout at the built commit with changes is dirty" do
    status = " M lib/a.ex\n?? lib/b.ex\n"

    assert %{status: "dirty", changed: 2} =
             SourceCheck.check(@vsn, System.tmp_dir!(), runner(@head, status))
  end

  test "a checkout whose changes cannot be listed is a git error, not a missing checkout" do
    git = fn
      ["rev-parse", "HEAD"], _folder -> {:ok, @head <> "\n"}
      ["status" | _], _folder -> :error
    end

    assert %{status: "git_error", ref: "3be90c014", head: @head} =
             SourceCheck.check(@vsn, System.tmp_dir!(), git)
  end

  test "a checkout at the built commit with no changes matches" do
    assert %{status: "match", ref: "3be90c014", changed: 0} =
             SourceCheck.check(@vsn, System.tmp_dir!(), runner(@head))
  end

  test "the git runner compares a real checkout" do
    dir = Path.join(System.tmp_dir!(), "source_check_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    git = fn args -> System.cmd("git", args, cd: dir, stderr_to_stdout: true) end
    {_, 0} = git.(["init", "-q"])

    {_, 0} =
      git.([
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@t",
        "commit",
        "-q",
        "--allow-empty",
        "-m",
        "x"
      ])

    {head, 0} = git.(["rev-parse", "HEAD"])
    ref = head |> String.trim() |> String.slice(0, 9)
    vsn = "1.0.0+build.1.ref" <> ref

    assert %{status: "match"} = SourceCheck.check(vsn, dir)
    assert %{status: "no_ref"} = SourceCheck.check("1.0.0", dir)

    File.write!(Path.join(dir, "new.ex"), "defmodule New do\nend\n")
    assert %{status: "dirty", changed: 1} = SourceCheck.check(vsn, dir)
  end
end
