defmodule Beamdash.NotebookStore do
  @moduledoc "Local .livemd storage with filename validation and optimistic concurrency."
  def directory,
    do:
      Application.get_env(:beamdash, :notebooks_dir) ||
        Path.join(:filename.basedir(:user_data, "beamdash"), "notebooks")

  def list(dir \\ directory()) do
    case File.ls(dir) do
      {:ok, names} ->
        {:ok,
         names |> Enum.filter(&(valid_name?(&1) and regular?(Path.join(dir, &1)))) |> Enum.sort()}

      {:error, :enoent} ->
        {:ok, []}

      error ->
        error
    end
  end

  def load(name, dir \\ directory()) do
    with :ok <- validate_name(name),
         path = Path.join(dir, name),
         true <- regular?(path),
         {:ok, %{size: size}} when size <= 2 * 1024 * 1024 <- File.stat(path),
         {:ok, source} <- File.read(path) do
      {:ok, source, version(source)}
    else
      false -> {:error, "Notebook is missing or is not a regular file."}
      {:ok, _} -> {:error, "Notebook exceeds the 2 MiB limit."}
      error -> error
    end
  end

  def save(name, source, expected, dir \\ directory()) do
    with :ok <- validate_name(name),
         true <- is_binary(source) and byte_size(source) <= 2 * 1024 * 1024,
         :ok <- File.mkdir_p(dir),
         path = Path.join(dir, name),
         {:ok, lock} <- lock(path <> ".lock") do
      temp = path <> ".tmp-#{System.unique_integer([:positive, :monotonic])}"

      try do
        with :ok <- check_version(name, expected, dir),
             :ok <- File.write(temp, source, [:exclusive]),
             :ok <- File.rename(temp, path) do
          {:ok, version(source)}
        end
      after
        unlock(lock)
        File.rm(temp)
      end
    else
      false -> {:error, "Notebook exceeds the 2 MiB limit."}
      error -> error
    end
  end

  # The helper holds an OS advisory lock until its stdin closes. If the VM is
  # killed, the OS closes the pipe and releases the lock automatically. The
  # inode is intentionally retained so concurrent processes lock the same file.
  defp lock(path) do
    case System.find_executable("python3") do
      nil ->
        {:error, "Notebook saving requires python3 for cross-process file locking."}

      executable ->
        script = """
        import fcntl, os, sys
        try:
            fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0), 0o600)
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            print('locked', flush=True)
            sys.stdin.buffer.read(1)
        except (OSError, ImportError):
            print('unavailable', flush=True)
            sys.exit(1)
        """

        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            :use_stdio,
            :stderr_to_stdout,
            args: ["-u", "-c", script, path]
          ])

        receive do
          {^port, {:data, "locked\n"}} ->
            {:ok, port}

          {^port, {:data, _}} ->
            Port.close(port)
            {:error, "Notebook is locked by another process or the lock is unavailable."}

          {^port, {:exit_status, _}} ->
            {:error, "Could not acquire notebook lock."}
        after
          5_000 ->
            Port.close(port)
            {:error, "Timed out acquiring notebook lock."}
        end
    end
  rescue
    _ -> {:error, "Could not start notebook lock helper."}
  end

  defp unlock(port) do
    Port.command(port, "q")

    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      5_000 -> Port.close(port)
    end
  rescue
    ArgumentError -> :ok
  end

  defp check_version(name, :new, dir) do
    case File.lstat(Path.join(dir, name)) do
      {:error, :enoent} -> :ok
      _ -> {:error, "A notebook with this name already exists. Open it or choose a new name."}
    end
  end

  defp check_version(name, expected, dir) do
    case load(name, dir) do
      {:ok, _, ^expected} ->
        :ok

      _ ->
        {:error,
         "The file changed or was removed since it was opened. Save under a new name to avoid overwriting it."}
    end
  end

  defp version(source), do: :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
  defp regular?(path), do: match?({:ok, %{type: :regular}}, File.lstat(path))

  defp valid_name?(name),
    do:
      is_binary(name) and String.valid?(name) and
        Regex.match?(~r/\A[^\/\\\x00]+\.livemd\z/u, name) and byte_size(name) <= 200

  defp validate_name(name),
    do:
      if(valid_name?(name),
        do: :ok,
        else: {:error, "Choose a filename ending in .livemd, without directory separators."}
      )
end
