defmodule Beamdash.Settings do
  @moduledoc """
  UI settings shared by every page. beamdash is a single-user local tool,
  so one global value is enough. Changes are broadcast on the
  `"settings"` PubSub topic as `{:beamdash_syntax, syntax}`,
  `{:beamdash_jev, enabled}`, `{:beamdash_backend, backend}` or
  `{:beamdash_kubeconfig_dir, dir}`.

  The syntax and Jev switch last for this VM's lifetime. The decision
  backend (Jev or Kev), the kubeconfig directory, auto-reconnect, local
  source folders and plugins' own settings are also saved, as JSON
  in `<user config dir>/beamdash/settings.json`
  (next to `Beamdash.LastConnection`'s file), so it is still chosen after a
  restart; `config :beamdash, :settings_file` points elsewhere, `false`
  turns saving off.
  """

  @key {__MODULE__, :syntax}
  @jev_key {__MODULE__, :jev_enabled}
  @backend_key {__MODULE__, :decision_backend}
  @nx_key {__MODULE__, :nx_enabled}
  @kev_port_key {__MODULE__, :kev_port}
  @kube_key {__MODULE__, :kubeconfig_dir}
  @reconnect_key {__MODULE__, :auto_reconnect}
  @source_dirs_key {__MODULE__, :source_dirs}
  @ai_key {__MODULE__, :ai_provider}
  @syntaxes [:erlang, :elixir]

  def syntaxes, do: @syntaxes

  @doc "Saved AI provider and model. API credentials are read from the environment."
  def ai_provider do
    case :persistent_term.get(@ai_key, :unset) do
      :unset ->
        saved = read()["ai_provider"]
        config = if is_map(saved), do: saved, else: %{}

        provider =
          if config["provider"] in ~w(none anthropic openai gemini),
            do: config["provider"],
            else: "none"

        model =
          if is_binary(config["model"]) and byte_size(config["model"]) <= 256,
            do: config["model"],
            else: ""

        result = %{"provider" => provider, "model" => model}
        :persistent_term.put(@ai_key, result)
        result

      config ->
        config
    end
  end

  def put_ai_provider(provider, model) when is_binary(provider) and is_binary(model) do
    model = String.trim(model)

    if provider in ~w(none anthropic openai gemini) and byte_size(model) <= 256 do
      config = %{"provider" => provider, "model" => model}
      :persistent_term.put(@ai_key, config)
      save("ai_provider", config)
      :ok
    else
      {:error, "Choose a supported provider and a model name of at most 256 bytes."}
    end
  end

  @doc "`:erlang` (default) or `:elixir`."
  def syntax, do: :persistent_term.get(@key, :erlang)

  def put_syntax(syntax) when syntax in @syntaxes do
    :persistent_term.put(@key, syntax)
    Phoenix.PubSub.broadcast(Beamdash.PubSub, "settings", {:beamdash_syntax, syntax})
    :ok
  end

  @doc """
  Whether Jev analysis is enabled for this running instance. Until it is
  switched in Settings, it is on only when an API key is configured:
  setting `TYPESAFE_API_KEY` is the opt-in.
  """
  def jev_enabled? do
    case :persistent_term.get(@jev_key, :unset) do
      :unset -> Beamdash.Jev.available?()
      enabled -> enabled
    end
  end

  def put_jev_enabled(enabled) when is_boolean(enabled) do
    :persistent_term.put(@jev_key, enabled)
    Phoenix.PubSub.broadcast(Beamdash.PubSub, "settings", {:beamdash_jev, enabled})
    :ok
  end

  @doc """
  The decision backend chosen in Settings (`:jev`, `:kev` or `:nx`), or `nil`
  when none was chosen (`Beamdash.Jev.backend/0` then decides). Saved for
  the next start.
  """
  def decision_backend do
    case :persistent_term.get(@backend_key, :unset) do
      :unset ->
        backend =
          case read()["decision_backend"] do
            "jev" -> :jev
            "kev" -> :kev
            "nx" -> :nx
            _ -> nil
          end

        :persistent_term.put(@backend_key, backend)
        backend

      backend ->
        backend
    end
  end

  @doc "Chooses `:jev`, `:kev` or `:nx`; `nil` forgets the choice."
  def put_decision_backend(backend) when backend in [:jev, :kev, :nx, nil] do
    :persistent_term.put(@backend_key, backend)
    save("decision_backend", backend && Atom.to_string(backend))
    Phoenix.PubSub.broadcast(Beamdash.PubSub, "settings", {:beamdash_backend, backend})
    :ok
  end

  @doc """
  The port of Kev's server set in Settings, replacing the one in `KEV_URL`
  or `KEV_PORT` (see `Beamdash.Jev`), or `nil`. Saved for the next start.
  """
  def kev_port do
    case :persistent_term.get(@kev_port_key, :unset) do
      :unset ->
        port = Beamdash.Jev.port(read()["kev_port"])
        :persistent_term.put(@kev_port_key, port)
        port

      port ->
        port
    end
  end

  @doc "Sets Kev's port (1..65535); `nil` goes back to the configured one."
  def put_kev_port(port) when port == nil or (is_integer(port) and port in 1..65_535) do
    :persistent_term.put(@kev_port_key, port)
    save("kev_port", port)
    :ok
  end

  @doc """
  Whether beamdash's local model (Nx) was switched on (`true`) or off
  (`false`) in Settings, or `nil` when never switched: `NX_MODEL` then
  decides (see `Beamdash.Jev.configured?/1`). Saved for the next start.
  """
  def nx_enabled do
    case :persistent_term.get(@nx_key, :unset) do
      :unset ->
        enabled = if is_boolean(read()["nx_enabled"]), do: read()["nx_enabled"]
        :persistent_term.put(@nx_key, enabled)
        enabled

      enabled ->
        enabled
    end
  end

  @doc """
  Switches the local model on or off (`nil` goes back to `NX_MODEL`). Open
  tabs follow: the backend in use and whether suggestions show are
  broadcast as on any other change.
  """
  def put_nx_enabled(enabled) when is_boolean(enabled) or enabled == nil do
    :persistent_term.put(@nx_key, enabled)
    # false must be saved too: it overrides NX_MODEL=true
    save("nx_enabled", enabled)

    Phoenix.PubSub.broadcast(
      Beamdash.PubSub,
      "settings",
      {:beamdash_backend, Beamdash.Jev.backend()}
    )

    Phoenix.PubSub.broadcast(Beamdash.PubSub, "settings", {:beamdash_jev, jev_enabled?()})
    :ok
  end

  @doc """
  Directory whose kubeconfig files the connection bar offers as clusters
  (see `Beamdash.Kubectl.list_kubeconfigs/1`). Until changed in Settings it
  is the `:kubeconfig_dir` application env, or `~/.kube`.
  """
  def kubeconfig_dir do
    case :persistent_term.get(@kube_key, nil) do
      nil ->
        dir = saved_kubeconfig_dir() || default_kubeconfig_dir()
        :persistent_term.put(@kube_key, dir)
        dir

      dir ->
        dir
    end
  end

  def default_kubeconfig_dir,
    do: Application.get_env(:beamdash, :kubeconfig_dir, Path.expand("~/.kube"))

  @doc """
  Expands `dir` (`~` included), makes it the kubeconfig directory and saves
  it for the next start. The default directory is saved as "nothing chosen",
  so a later change of the default still applies.
  """
  def put_kubeconfig_dir(dir) when is_binary(dir) do
    dir = Path.expand(dir)
    :persistent_term.put(@kube_key, dir)
    save("kubeconfig_dir", if(dir == default_kubeconfig_dir(), do: nil, else: dir))
    Phoenix.PubSub.broadcast(Beamdash.PubSub, "settings", {:beamdash_kubeconfig_dir, dir})
    :ok
  end

  @doc "Goes back to the default kubeconfig directory (and forgets the saved one)."
  def reset_kubeconfig_dir, do: put_kubeconfig_dir(default_kubeconfig_dir())

  @doc """
  Whether a lost connection is tried again (see `Beamdash.Target`). Off
  until switched on in Settings; saved for the next start.
  """
  def auto_reconnect? do
    case :persistent_term.get(@reconnect_key, nil) do
      nil ->
        enabled = read()["auto_reconnect"] == true
        :persistent_term.put(@reconnect_key, enabled)
        enabled

      enabled ->
        enabled
    end
  end

  def put_auto_reconnect(enabled) when is_boolean(enabled) do
    :persistent_term.put(@reconnect_key, enabled)
    save("auto_reconnect", if(enabled, do: true))
    :ok
  end

  @doc """
  Local folders holding applications' source code, `%{app_name => dir}`, for
  modules whose source isn't on the node (a release in a Kubernetes pod,
  say; see `Beamdash.LocalSource`). Saved for the next start.
  """
  def source_dirs do
    case :persistent_term.get(@source_dirs_key, nil) do
      nil ->
        dirs =
          case read()["source_dirs"] do
            %{} = saved -> for {app, dir} when is_binary(dir) <- saved, into: %{}, do: {app, dir}
            _ -> %{}
          end

        :persistent_term.put(@source_dirs_key, dirs)
        dirs

      dirs ->
        dirs
    end
  end

  @doc "Sets `app`'s source folder to `dir` (`~` expanded) and saves it."
  def put_source_dir(app, dir) when is_binary(app) and is_binary(dir) do
    put_source_dirs(Map.put(source_dirs(), app, Path.expand(dir)))
  end

  @doc "Forgets `app`'s source folder."
  def delete_source_dir(app) when is_binary(app) do
    put_source_dirs(Map.delete(source_dirs(), app))
  end

  defp put_source_dirs(dirs) do
    :persistent_term.put(@source_dirs_key, dirs)
    save("source_dirs", if(dirs != %{}, do: dirs))
    :ok
  end

  @doc """
  Plugin `plugin`'s saved value for `key` (see `Beamdash.Plugin.get_setting/3`),
  or `default`. Read from the file each time: plugins read them rarely.
  """
  def plugin_setting(plugin, key, default) when is_atom(plugin) and is_binary(key) do
    case read()["plugin_settings"] do
      %{} = all -> all |> Map.get(Atom.to_string(plugin), %{}) |> then(&Map.get(&1, key, default))
      _ -> default
    end
  end

  @doc "Saves plugin `plugin`'s `value` for `key`; `nil` removes it."
  def put_plugin_setting(plugin, key, value) when is_atom(plugin) and is_binary(key) do
    all =
      case read()["plugin_settings"] do
        %{} = all -> all
        _ -> %{}
      end

    name = Atom.to_string(plugin)

    own =
      all
      |> Map.get(name, %{})
      |> then(&if(value == nil, do: Map.delete(&1, key), else: Map.put(&1, key, value)))

    all = if own == %{}, do: Map.delete(all, name), else: Map.put(all, name, own)
    save("plugin_settings", if(all != %{}, do: all))
    :ok
  end

  @doc "The file the settings are saved in, or `nil` when saving is off."
  def path do
    case Application.get_env(:beamdash, :settings_file) do
      false -> nil
      nil -> Path.join(:filename.basedir(:user_config, "beamdash"), "settings.json")
      path -> path
    end
  end

  @doc false
  # Drops the in-memory copy so the next read loads the file (tests).
  def reload do
    :persistent_term.erase(@backend_key)
    :persistent_term.erase(@nx_key)
    :persistent_term.erase(@kev_port_key)
    :persistent_term.erase(@kube_key)
    :persistent_term.erase(@reconnect_key)
    :persistent_term.erase(@source_dirs_key)
    :persistent_term.erase(@ai_key)
    :ok
  end

  defp saved_kubeconfig_dir do
    case read()["kubeconfig_dir"] do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> nil
    end
  end

  # A missing, unreadable or broken file reads as no saved settings.
  defp read do
    with path when is_binary(path) <- path(),
         {:ok, json} <- File.read(path),
         {:ok, %{} = saved} <- Jason.decode(json) do
      saved
    else
      _ -> %{}
    end
  end

  # Other keys in the file are kept; `nil` removes `key`. Written to a temp
  # file then renamed, so a crash never leaves half a file. A failure to
  # save only loses the setting at the next start, so it is not an error.
  defp save(key, value) do
    with path when is_binary(path) <- path(),
         :ok <- File.mkdir_p(Path.dirname(path)),
         saved = if(value == nil, do: Map.delete(read(), key), else: Map.put(read(), key, value)),
         tmp = path <> ".tmp",
         :ok <- File.write(tmp, Jason.encode!(saved)),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      _ -> :ok
    end
  end
end
