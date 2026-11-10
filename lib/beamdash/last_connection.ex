defmodule Beamdash.LastConnection do
  @moduledoc """
  The connections the connection bar offers again, also after a restart,
  most recent first. A plain node keeps its node and cookie. A Kubernetes
  connection also keeps the kubeconfig, namespace, pod, container and binary,
  and the node and cookie read from the pod, so reconnecting needs no kubectl
  listing.

  Saved after a successful connection, as JSON in
  `<user config dir>/beamdash/last_connection.json` (on macOS
  `~/Library/Application Support/beamdash`, on Linux `~/.config/beamdash`),
  readable by the owner only. A file from before the list, holding one node
  and cookie, is read as one entry. `config :beamdash, :last_connection_file`
  points elsewhere; `false` turns remembering off.

  An entry is a map with string keys: `id`, `kind` (`"node"` or `"kubectl"`),
  `node`, `cookie`, and for `"kubectl"` also `kubeconfig`, `namespace`, `pod`,
  `container` and `binary` (`""` where unused).
  """

  @cache {__MODULE__, :saved}
  @max 10
  @fields ~w(kind node cookie kubeconfig namespace pod container binary)
  @identity_fields ~w(kind kubeconfig namespace pod container binary)

  @doc "The saved connections, most recent first."
  def list do
    case :persistent_term.get(@cache, nil) do
      nil ->
        saved = read()
        :persistent_term.put(@cache, saved)
        saved

      saved ->
        saved
    end
  end

  @doc """
  Puts a connection that worked first, in place of a saved one with the same
  node (or the same pod, container and binary). `attrs` has string keys, see
  the moduledoc; a new `id` is given.
  """
  def put(attrs) do
    case normalize(Map.put(attrs, "id", id())) do
      nil ->
        :ok

      entry ->
        others = Enum.reject(list(), &(identity(&1) == identity(entry)))
        store(Enum.take([entry | others], @max))
    end
  end

  @doc "Deletes the saved connection with this `id`."
  def delete(id), do: store(Enum.reject(list(), &(&1["id"] == id)))

  @doc "Forgets every saved connection."
  def forget do
    :persistent_term.put(@cache, [])

    case path() do
      nil -> :ok
      path -> File.rm(path) |> then(fn _ -> :ok end)
    end
  end

  @doc "The file it is kept in, or `nil` when remembering is off."
  def path do
    case Application.get_env(:beamdash, :last_connection_file) do
      false -> nil
      nil -> Path.join(:filename.basedir(:user_config, "beamdash"), "last_connection.json")
      path -> path
    end
  end

  @doc false
  # Drops the in-memory copy so the next `list/0` reads the file (tests).
  def reload, do: :persistent_term.erase(@cache) |> then(fn _ -> :ok end)

  defp store(saved) do
    :persistent_term.put(@cache, saved)
    write(saved)
  end

  defp identity(%{"kind" => "node", "node" => node}), do: {"node", node}
  defp identity(entry), do: Map.take(entry, @identity_fields)

  defp id, do: :crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false)

  defp normalize(%{"node" => node} = attrs) when is_binary(node) and node != "" do
    entry = Map.new(@fields, &{&1, text(attrs[&1])})
    kind = if entry["kind"] == "kubectl", do: "kubectl", else: "node"
    Map.merge(entry, %{"id" => text(attrs["id"]), "kind" => kind})
  end

  defp normalize(_attrs), do: nil

  defp text(value), do: if(is_binary(value), do: value, else: "")

  defp read do
    with path when is_binary(path) <- path(),
         {:ok, json} <- read_file(path),
         {:ok, map} when is_map(map) <- Jason.decode(json) do
      decode(map)
    else
      _ -> []
    end
  end

  defp decode(%{"connections" => list}) when is_list(list),
    do: list |> Enum.flat_map(&List.wrap(normalize_saved(&1))) |> Enum.take(@max)

  defp decode(legacy), do: List.wrap(normalize_saved(legacy))

  defp normalize_saved(%{"id" => id} = map) when is_binary(id) and id != "", do: normalize(map)
  defp normalize_saved(map) when is_map(map), do: normalize(Map.put(map, "id", id()))
  defp normalize_saved(_other), do: nil

  # Before the renames to beamdash the file was in the exberly folder, and
  # before that in elixberly: read it from there until a connection saves it
  # in the new place.
  defp read_file(path) do
    case File.read(path) do
      {:error, :enoent} -> read_legacy(legacy_paths(path))
      other -> other
    end
  end

  defp read_legacy([]), do: {:error, :enoent}

  defp read_legacy([old | rest]) do
    case File.read(old) do
      {:error, :enoent} -> read_legacy(rest)
      other -> other
    end
  end

  @doc false
  def legacy_paths(path) do
    file = &Path.join(:filename.basedir(:user_config, &1), "last_connection.json")
    if path == file.("beamdash"), do: [file.("exberly"), file.("elixberly")], else: []
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
         :ok <- File.write(tmp, Jason.encode!(%{"connections" => saved})),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      nil -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
