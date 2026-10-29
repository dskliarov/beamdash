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

  # A loopback listener is released by the OS on process exit. Identical
  # directory identities and filenames map to the same port across local VMs.
  # Hash collisions fail closed; they can temporarily block an unrelated save.
  defp lock(path) do
    with {:ok, stat} <- File.stat(Path.dirname(path)) do
      key = {stat.major_device, stat.minor_device, stat.inode, Path.basename(path)}
      <<hash::unsigned-16, _::binary>> = :crypto.hash(:sha256, :erlang.term_to_binary(key))
      port = 1024 + rem(hash, 64_512)

      case :gen_tcp.listen(port, [:binary, active: false, reuseaddr: false, ip: {127, 0, 0, 1}]) do
        {:ok, socket} ->
          {:ok, socket}

        {:error, :eaddrinuse} ->
          {:error, "Notebook lock is busy; retry or choose a different filename."}

        {:error, reason} ->
          {:error, "Cannot acquire notebook lock: #{inspect(reason)}"}
      end
    end
  end

  defp unlock(socket), do: :gen_tcp.close(socket)

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
