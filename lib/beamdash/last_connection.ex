defmodule Beamdash.LastConnection do
  @moduledoc """
  The last node beamdash connected to, and the cookie used, so the
  connection bar can offer them again, also after a restart.

  Saved only after a successful connection, as JSON in
  `<user config dir>/beamdash/last_connection.json` (on macOS
  `~/Library/Application Support/beamdash`, on Linux `~/.config/beamdash`),
  readable by the owner only. `config :beamdash, :last_connection_file`
  points elsewhere; `false` turns remembering off.
  """

  @cache {__MODULE__, :saved}
  @empty %{node: "", cookie: ""}

  @doc "`%{node: string, cookie: string}`; empty strings when nothing is saved."
  def get do
    case :persistent_term.get(@cache, nil) do
      nil ->
        saved = read()
        :persistent_term.put(@cache, saved)
        saved

      saved ->
        saved
    end
  end

  @doc "Remembers a node and cookie that connected (`nil` cookie: none typed)."
  def put(node, cookie) do
    saved = %{node: to_string(node), cookie: cookie || ""}
    :persistent_term.put(@cache, saved)
    write(saved)
  end

  @doc "Forgets the saved node and cookie."
  def forget do
    :persistent_term.put(@cache, @empty)

    case path() do
      nil -> :ok
      path -> File.rm(path) |> then(fn _ -> :ok end)
    end
  end

  def saved?, do: get().node != ""

  @doc "The file it is kept in, or `nil` when remembering is off."
  def path do
    case Application.get_env(:beamdash, :last_connection_file) do
      false -> nil
      nil -> Path.join(:filename.basedir(:user_config, "beamdash"), "last_connection.json")
      path -> path
    end
  end

  @doc false
  # Drops the in-memory copy so the next `get/0` reads the file (tests).
  def reload, do: :persistent_term.erase(@cache) |> then(fn _ -> :ok end)

  defp read do
    with path when is_binary(path) <- path(),
         {:ok, json} <- read_file(path),
         {:ok, %{"node" => node} = map} when is_binary(node) <- Jason.decode(json) do
      cookie = map["cookie"]
      %{node: node, cookie: if(is_binary(cookie), do: cookie, else: "")}
    else
      _ -> @empty
    end
  end

  # Before the rename to beamdash the file was in the exberly folder: read
  # it from there until a connection saves it in the new place.
  defp read_file(path) do
    case File.read(path) do
      {:error, :enoent} -> if old = legacy_path(path), do: File.read(old), else: {:error, :enoent}
      other -> other
    end
  end

  @doc false
  def legacy_path(path) do
    default = Path.join(:filename.basedir(:user_config, "beamdash"), "last_connection.json")

    if path == default,
      do: Path.join(:filename.basedir(:user_config, "exberly"), "last_connection.json")
  end

  # The cookie gives full control of the node: owner-only file and folder.
  defp write(saved) do
    with path when is_binary(path) <- path(),
         dir = Path.dirname(path),
         :ok <- File.mkdir_p(dir),
         _ <- File.chmod(dir, 0o700),
         tmp = path <> ".tmp",
         :ok <- File.write(tmp, ""),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.write(tmp, Jason.encode!(saved)),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      nil -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
