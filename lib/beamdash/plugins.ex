defmodule Beamdash.Plugins do
  @moduledoc """
  The installed plugins: installs, removes and rebuilds them, loads them at
  startup, and tracks which ones fit the attached node.

  The list is kept in `<plugins dir>/plugins.json`; each plugin's beams are
  in `<plugins dir>/<app>/ebin`, and a Git or Hex plugin's source in
  `<plugins dir>/<app>/src`. A path plugin is built from its own folder,
  which is never changed or deleted.

  An install runs in a task under `Beamdash.Plugins.TaskSup`. It sends the
  caller `{:beamdash_plugins, {:install, ref, step}}` for each step
  (`:checking`, `:fetching`, `:compiling`, `:loading`), then
  `{:beamdash_plugins, {:installed, ref, app}}` or
  `{:beamdash_plugins, {:install_failed, ref, message}}`. Only the final
  bookkeeping runs in this process.

  On the `"plugins"` PubSub topic it broadcasts `{:beamdash_plugins,
  :changed}` when a plugin is installed, rebuilt or removed, or a status
  changes, and `{:beamdash_plugins, {:removed, app}}` when one is removed.

  At startup each plugin whose beams are there and up to date is loaded at
  once. The others (no beams yet, or a path plugin whose source is newer)
  show as `:building` and are compiled in one task under
  `Beamdash.Plugins.TaskSup`, so this process keeps answering meanwhile. A
  build that fails keeps the last good beams, if any, loaded (its error is
  in `build_error`); with none the plugin is `{:failed, message}`.

  A rebuild and a remove of a plugin don't overlap: while it is being
  rebuilt (or built at startup) another rebuild or a remove is refused with
  `{:error, message}`.

  A broken plugin shows as `{:failed, message}`; it never stops this process.
  """

  use GenServer
  require Logger

  alias Beamdash.{Apps, Target}
  alias Beamdash.Plugins.{Build, Compat, Fetch, Spec}

  @topic "plugins"
  @app_re ~r/\A[a-z][a-z0-9_]{0,63}\z/

  defstruct dir: nil,
            target: Target,
            refresh_ms: 10_000,
            task_sup: Beamdash.Plugins.TaskSup,
            pubsub: Beamdash.PubSub,
            plugins: %{},
            node: nil,
            # [{app, vsn}] of the attached node; [] when not connected
            running: [],
            statuses: %{},
            refresh: nil,
            installing: nil,
            # app => {caller pid, monitor ref} of the rebuild running
            rebuilding: %{},
            # %{ref, pid} of the startup build task, while it runs
            startup: nil

  ## API

  @doc """
  Options: `name:`, `dir:` (the plugins dir, default `Build.plugins_dir/0`;
  deletions are only allowed inside `Build.plugins_dir/0`), `target:` and
  `refresh_ms:` (how often the running applications are read, default
  10 s).
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  The installed plugins, sorted by app: `%{app, spec_text, source, resolved,
  supports, status, plugin, modules, build_error}`. `status` is `:building`
  (compiled at startup, not loaded yet), `{:failed, message}`, `:waiting`,
  `{:incompatible, app, running_vsn, requirement}` or `:active` (see
  `Beamdash.Plugins.Compat`); `plugin` is `%{name, pages}`, or `nil` while
  building or when it failed to load. `build_error` is the message of a
  startup build that failed while the last good build was loaded instead,
  else `nil`.
  """
  def list(server \\ __MODULE__), do: GenServer.call(server, :list)

  @doc "The active plugins, sorted by name: `%{app, name, pages: [%{slug, label, module}]}`."
  def active(server \\ __MODULE__), do: GenServer.call(server, :active)

  @doc """
  The page `slug` of plugin `app` (a string, from the URL): `{:ok, %{app,
  module, plugin, page}}` (`module` is the entry module), or `{:error, :not_found | :building | :waiting |
  {:incompatible, app, vsn, req}}`. `:building` while the plugin is compiled
  at startup (its pages aren't known yet).
  """
  def page(server \\ __MODULE__, app, slug), do: GenServer.call(server, {:page, app, slug})

  @doc """
  The stylesheet of plugin `app` (a string, from the URL, or an atom):
  `{:ok, path}` of `priv/static/plugin.css` in its source (a path plugin's
  folder, else `<plugins dir>/<app>/src`) when the plugin is installed and
  the file exists, else `:error`. A symlink on the way (`priv`,
  `priv/static` or the file) is refused, so the file is inside the source.
  """
  def css_path(server \\ __MODULE__, app), do: GenServer.call(server, {:css_path, app})

  @doc "The plugins dir of `server`."
  def dir(server \\ __MODULE__), do: GenServer.call(server, :dir)

  @doc """
  Starts installing the plugin described by `text` (Mix dependency syntax)
  and returns at once; see the moduledoc for the messages sent to the
  caller. `{:error, message}` while another install runs.
  """
  def install(server \\ __MODULE__, text), do: GenServer.call(server, {:install, text, self()})

  @doc """
  Unloads plugin `app` and deletes its folder in the plugins dir. When the
  folder can't be deleted the plugin is still removed, and the error names
  the folder.
  """
  def remove(server \\ __MODULE__, app), do: GenServer.call(server, {:remove, app}, 30_000)

  @doc """
  Recompiles a path plugin from its folder and swaps its modules. On
  failure the old code stays loaded. The compile runs in the caller; one
  rebuild of a plugin runs at a time (`{:error, message}` meanwhile), and
  it ends when the caller exits.
  """
  def rebuild(server \\ __MODULE__, app) do
    with {:ok, entry, install_dir} <- GenServer.call(server, {:rebuild_info, app}) do
      result = guarded(fn -> build_new(entry, install_dir) end)
      GenServer.call(server, {:rebuild_commit, entry.app, result}, 30_000)
    end
  end

  ## GenServer

  @impl true
  def init(opts) do
    state = %__MODULE__{
      dir: Keyword.get_lazy(opts, :dir, &Build.plugins_dir/0),
      target: Keyword.get(opts, :target, Target),
      refresh_ms: Keyword.get(opts, :refresh_ms, 10_000),
      task_sup: Keyword.get(opts, :task_sup, Beamdash.Plugins.TaskSup),
      pubsub: Keyword.get(opts, :pubsub, Beamdash.PubSub)
    }

    {:ok, state, {:continue, :init}}
  end

  @impl true
  def handle_continue(:init, state) do
    sweep(state.dir)

    {plugins, jobs} =
      Enum.reduce(read_saved(state.dir), {%{}, []}, fn saved, {plugins, jobs} ->
        case startup_entry(saved, state.dir) do
          {:loaded, entry} -> {Map.put(plugins, entry.app, entry), jobs}
          {:build, entry, job} -> {Map.put(plugins, entry.app, entry), [job | jobs]}
        end
      end)

    :ok = Target.subscribe(state.target)

    state = start_builds(%{state | plugins: plugins}, Enum.reverse(jobs))

    state =
      case Target.status(state.target) do
        %{status: :connected, node: node} -> refresh(%{state | node: node})
        _ -> state
      end

    {:noreply, recompute(state)}
  end

  @impl true
  def handle_call(:list, _from, state) do
    list =
      state.plugins
      |> Map.values()
      |> Enum.sort_by(& &1.app)
      |> Enum.map(&public(&1, state))

    {:reply, list, state}
  end

  def handle_call(:active, _from, state) do
    active =
      for {app, entry} <- state.plugins, status(entry, state) == :active do
        %{app: app, name: entry.plugin.name, pages: entry.plugin.pages}
      end

    {:reply, Enum.sort_by(active, & &1.name), state}
  end

  def handle_call({:page, app, slug}, _from, state) do
    with %{building: false, plugin: %{} = plugin} = entry <- find(state, app),
         %{} = page <- Enum.find(plugin.pages, &(&1.slug == slug)) do
      case status(entry, state) do
        :active ->
          {:reply, {:ok, %{app: entry.app, module: entry.prefix, plugin: plugin, page: page}},
           state}

        {:failed, _} ->
          {:reply, {:error, :not_found}, state}

        other ->
          {:reply, {:error, other}, state}
      end
    else
      %{building: true} -> {:reply, {:error, :building}, state}
      _ -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:css_path, app}, _from, state) do
    reply =
      with %{} = entry <- find(state, app),
           src = source_dir(state, entry),
           true <- no_links?(src, ["priv", "static", "plugin.css"]) do
        {:ok, Path.join(src, "priv/static/plugin.css")}
      else
        _ -> :error
      end

    {:reply, reply, state}
  end

  def handle_call(:dir, _from, state), do: {:reply, state.dir, state}

  def handle_call({:install, _text, _caller}, _from, %{installing: %{}} = state) do
    {:reply, {:error, "another plugin is being installed"}, state}
  end

  def handle_call({:install, text, caller}, _from, state) do
    ref = make_ref()
    tmp = Path.join(state.dir, ".tmp-#{System.unique_integer([:positive])}")
    server = self()
    installed = Map.keys(state.plugins)

    task =
      Task.Supervisor.async_nolink(state.task_sup, fn ->
        run_install(server, caller, ref, text, tmp, installed)
      end)

    installing = %{ref: ref, task: task.ref, pid: task.pid, caller: caller, tmp: tmp}
    {:reply, {:ok, ref}, %{state | installing: installing}}
  end

  def handle_call({:commit, entry, tmp}, _from, state) do
    case commit(entry, tmp, state) do
      {:ok, entry} ->
        new_state = put_in(state.plugins[entry.app], entry)

        case save(new_state) do
          :ok ->
            broadcast(new_state, :changed)
            {:reply, :ok, recompute(new_state)}

          {:error, _} = error ->
            # not recorded, so not kept either
            Build.unload(entry.modules)
            Build.safe_rm_rf(install_dir(state, entry.app))
            {:reply, error, state}
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:remove, app}, _from, state) do
    with %{} = entry <- find(state, app),
         nil <- busy(state, entry.app),
         new_state = %{state | plugins: Map.delete(state.plugins, entry.app)},
         :ok <- save(new_state) do
      Build.unload(entry.modules)
      install_dir = install_dir(state, entry.app)
      broadcast(new_state, {:removed, entry.app})
      broadcast(new_state, :changed)
      state = recompute(new_state)

      case Build.safe_rm_rf(install_dir) do
        :ok ->
          {:reply, :ok, state}

        {:error, msg} ->
          {:reply, {:error, "#{entry.app} is removed, but #{install_dir} is left: #{msg}"}, state}
      end
    else
      nil -> {:reply, {:error, "#{app} is not installed"}, state}
      msg when is_binary(msg) -> {:reply, {:error, msg}, state}
      {:error, msg} -> {:reply, {:error, "#{app} is not removed: #{msg}"}, state}
    end
  end

  # Takes the rebuild slot of `app` for the caller, until it commits or exits.
  def handle_call({:rebuild_info, app}, {caller, _}, state) do
    case find(state, app) do
      nil ->
        {:reply, {:error, "#{app} is not installed"}, state}

      %{source: :path} = entry ->
        case busy(state, entry.app) do
          nil ->
            mref = Process.monitor(caller)
            state = put_in(state.rebuilding[entry.app], {caller, mref})
            {:reply, {:ok, entry, install_dir(state, entry.app)}, state}

          msg ->
            {:reply, {:error, msg}, state}
        end

      _ ->
        {:reply, {:error, "only path plugins can be rebuilt"}, state}
    end
  end

  def handle_call({:rebuild_commit, app, result}, {caller, _}, state) do
    case state.rebuilding[app] do
      {^caller, mref} ->
        Process.demonitor(mref, [:flush])
        state = %{state | rebuilding: Map.delete(state.rebuilding, app)}
        rebuild_commit(state, app, result)

      _ ->
        with {:ok, built} <- result, do: Build.safe_rm_rf(built.ebin_new)
        {:reply, {:error, "no rebuild of #{app} is running"}, state}
    end
  end

  @impl true
  def handle_info({:beamdash_target, {:connected, node}}, state) do
    {:noreply, refresh(%{state | node: node})}
  end

  def handle_info({:beamdash_target, {:disconnected, _}}, state) do
    if state.refresh, do: Process.cancel_timer(state.refresh)
    {:noreply, recompute(%{state | node: nil, running: [], refresh: nil})}
  end

  def handle_info({:refresh, node}, %{node: node} = state), do: {:noreply, refresh(state)}
  def handle_info({:refresh, _old}, state), do: {:noreply, state}

  def handle_info({:running, node, running}, %{node: node} = state) do
    {:noreply, recompute(%{state | running: running})}
  end

  def handle_info({:running, _old, _}, state), do: {:noreply, state}

  # the install task's result (it sent its own messages to the caller)
  def handle_info({ref, _result}, %{installing: %{task: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | installing: nil}}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{installing: %{task: ref} = i} = state) do
    Build.stop_compile(pid)
    # a compile cut short leaves its ebin on the code path, and what it
    # compiled so far loaded
    ebin = Path.join(i.tmp, "ebin")
    Code.delete_path(ebin)
    unload_stray([ebin], nil, [])
    Build.safe_rm_rf(i.tmp)

    send(
      i.caller,
      {:beamdash_plugins, {:install_failed, i.ref, "install crashed: #{inspect(reason)}"}}
    )

    {:noreply, %{state | installing: nil}}
  end

  def handle_info({:startup_built, app, result}, state) do
    case state.plugins[app] do
      %{building: true} = entry ->
        entry = finish_build(entry, result, install_dir(state, app))
        state = put_in(state.plugins[app], entry)

        # records the prefix of an entry saved before it was
        if entry.failed == nil and entry.build_error == nil do
          with {:error, msg} <- save(state), do: Logger.warning("beamdash: #{msg}")
        end

        {:noreply, recompute(state)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({ref, _result}, %{startup: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_builds(%{state | startup: nil}, "the build did not finish")}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{startup: %{ref: ref}} = state) do
    Build.stop_compile(pid)
    {:noreply, finish_builds(%{state | startup: nil}, "the build crashed: #{inspect(reason)}")}
  end

  # a rebuilding caller exited before committing
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Enum.find(state.rebuilding, fn {_app, {_pid, mref}} -> mref == ref end) do
      {app, _} ->
        Build.stop_compile(pid)
        abort_rebuild(state, app)
        {:noreply, %{state | rebuilding: Map.delete(state.rebuilding, app)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Install (in the task)

  defp run_install(server, caller, ref, text, tmp, installed) do
    step = fn step -> send(caller, {:beamdash_plugins, {:install, ref, step}}) end

    result =
      try do
        install_steps(server, text, tmp, installed, step)
      rescue
        error -> {:error, Exception.message(error)}
      after
        Build.safe_rm_rf(tmp)
      end

    case result do
      {:ok, app} -> send(caller, {:beamdash_plugins, {:installed, ref, app}})
      {:error, msg} -> send(caller, {:beamdash_plugins, {:install_failed, ref, msg}})
    end

    :ok
  end

  defp install_steps(server, text, tmp, installed, step) do
    step.(:checking)

    with {:ok, spec} <- Spec.parse(text),
         :ok <- not_installed(spec.app, installed),
         step.(:fetching),
         :ok <- mkdir(tmp),
         {:ok, %{src: src, resolved: resolved}} <- Fetch.fetch(spec, tmp),
         step.(:compiling),
         {:ok, project} <- read_project(src, spec.app),
         {:ok, built} <- build(src, Path.join(tmp, "ebin")),
         step.(:loading) do
      entry = %{
        app: spec.app,
        spec_text: Spec.to_string(spec),
        source: spec.source,
        resolved: resolved,
        supports: project.supports,
        installed_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        prefix: built.prefix,
        plugin: built.plugin,
        modules: built.modules,
        failed: nil,
        building: false,
        build_error: nil
      }

      with :ok <- GenServer.call(server, {:commit, entry, tmp}, 60_000), do: {:ok, spec.app}
    end
  end

  defp not_installed(app, installed) do
    if app in installed, do: {:error, "#{app} is already installed"}, else: :ok
  end

  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot create #{dir}: #{:file.format_error(reason)}"}
    end
  end

  defp read_project(src, app) do
    case Build.read_project(src) do
      {:ok, %{app: ^app} = project} ->
        {:ok, project}

      {:ok, %{app: other}} ->
        {:error, "mix.exs says app: :#{other}, but the dependency is :#{app}"}

      error ->
        error
    end
  end

  # scan, compile, check: nothing is loaded
  defp build(src, ebin, allow \\ []) do
    with {:ok, %{prefix: prefix, modules: expected}} <- Build.scan(src, allow: allow),
         {:ok, modules} <- Build.compile(src, ebin, expected),
         {:ok, plugin} <- Build.check(modules, prefix, ebin) do
      {:ok, %{modules: modules, prefix: prefix, plugin: plugin}}
    end
  end

  # In this process, so the app can't be installed twice.
  defp commit(entry, tmp, state) do
    install_dir = install_dir(state, entry.app)
    ebin = Path.join(install_dir, "ebin")

    with :ok <- not_installed(entry.app, Map.keys(state.plugins)),
         :ok <- Build.safe_rm_rf(install_dir),
         :ok <- rename(tmp, install_dir),
         :ok <- load_or_clean(entry.modules, ebin, install_dir) do
      {:ok, entry}
    end
  end

  defp load_or_clean(modules, ebin, install_dir) do
    case Build.load(modules, ebin) do
      :ok ->
        :ok

      {:error, _} = error ->
        Build.safe_rm_rf(install_dir)
        error
    end
  end

  defp rename(from, to) do
    case File.rename(from, to) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot move #{from} to #{to}: #{:file.format_error(reason)}"}
    end
  end

  ## Rebuild

  # In the caller: build into ebin.new; the old code stays loaded.
  defp build_new(entry, install_dir) do
    src = entry.resolved
    ebin_new = Path.join(install_dir, "ebin.new")
    old_ebin = Path.join(install_dir, "ebin")

    with :ok <- Build.safe_rm_rf(ebin_new),
         {:ok, project} <- read_project(src, entry.app),
         {:ok, built} <- build(src, ebin_new, entry.modules) do
      {:ok, Map.merge(built, %{ebin_new: ebin_new, supports: project.supports})}
    else
      {:error, _} = error ->
        Build.safe_rm_rf(ebin_new)
        # the compiler may have replaced loaded modules of the plugin
        restore(entry.modules, old_ebin)
        error
    end
  end

  defp rebuild_commit(state, app, {:ok, built}) do
    case find(state, app) do
      nil ->
        Build.safe_rm_rf(built.ebin_new)
        {:reply, {:error, "#{app} is not installed"}, state}

      entry ->
        case swap(entry, built, install_dir(state, entry.app)) do
          {:ok, entry} ->
            state = put_in(state.plugins[entry.app], entry)
            broadcast(state, :changed)

            case save(state) do
              :ok ->
                {:reply, :ok, recompute(state)}

              {:error, msg} ->
                {:reply, {:error, "#{app} is rebuilt, but #{msg}"}, recompute(state)}
            end

          {:error, msg} ->
            {:reply, {:error, msg}, state}

          {:failed, msg, why} ->
            entry = %{entry | failed: why, plugin: nil, modules: []}
            state = put_in(state.plugins[entry.app], entry)
            with {:error, save_msg} <- save(state), do: Logger.warning("beamdash: #{save_msg}")
            {:reply, {:error, msg}, recompute(state)}
        end
    end
  end

  defp rebuild_commit(state, app, {:error, _} = error) do
    abort_rebuild(state, app)
    {:reply, error, state}
  end

  # After a rebuild that failed or was cut short: ebin.new goes (also from
  # the code path), what its compile loaded is unloaded, and the plugin's
  # own modules are loaded from ebin again.
  defp abort_rebuild(state, app) do
    install_dir = install_dir(state, app)
    ebin_new = Path.join(install_dir, "ebin.new")
    Code.delete_path(ebin_new)
    Build.safe_rm_rf(ebin_new)

    if entry = state.plugins[app] do
      unload_stray([ebin_new], entry.prefix, entry.modules)
      restore(entry.modules, Path.join(install_dir, "ebin"))
    end

    :ok
  end

  # Unloads the modules not in `keep` that were loaded from a beam in one of
  # `dirs`, or loaded in memory (no beam file) and named under `prefix`. A
  # module loaded from anywhere else is never touched, whatever its name.
  defp unload_stray(dirs, prefix, keep) do
    dirs = Enum.map(dirs, &Path.expand/1)
    base = prefix && Atom.to_string(prefix)

    stray =
      for {module, path} <- :code.all_loaded(),
          module not in keep,
          from_dirs?(path, dirs) or (path == [] and named_under?(module, base)),
          do: module

    Build.unload(stray)
  end

  defp from_dirs?(path, dirs) when is_list(path) and path != [],
    do: Path.dirname(Path.expand(List.to_string(path))) in dirs

  defp from_dirs?(_path, _dirs), do: false

  defp named_under?(_module, nil), do: false

  defp named_under?(module, base) do
    name = Atom.to_string(module)
    name == base or String.starts_with?(name, base <> ".")
  end

  # Puts built.ebin_new in place of ebin and loads it. On failure the old
  # beams go back and are loaded again: `{:error, msg}`, or `{:failed, msg,
  # why}` when even that fails (then nothing of the plugin is loaded).
  defp swap(entry, built, install_dir) do
    ebin = Path.join(install_dir, "ebin")
    ebin_old = Path.join(install_dir, "ebin.old")

    Build.unload(Enum.uniq(entry.modules ++ built.modules))
    Build.safe_rm_rf(ebin_old)

    with :ok <- rename_if_exists(ebin, ebin_old),
         :ok <- rename(built.ebin_new, ebin),
         :ok <- Build.load(built.modules, ebin) do
      Build.safe_rm_rf(ebin_old)

      {:ok,
       %{
         entry
         | plugin: built.plugin,
           modules: built.modules,
           supports: built.supports,
           prefix: built.prefix,
           failed: nil,
           building: false,
           build_error: nil
       }}
    else
      {:error, msg} ->
        Build.unload(built.modules)
        Build.safe_rm_rf(built.ebin_new)

        case roll_back(entry.modules, ebin, ebin_old) do
          :ok ->
            {:error, msg}

          {:error, why} ->
            Build.unload(entry.modules)
            {:failed, msg, "#{msg}; the old version could not be loaded again: #{why}"}
        end
    end
  end

  # back to the old version
  defp roll_back(modules, ebin, ebin_old) do
    with :ok <- if(File.dir?(ebin_old), do: put_back(ebin_old, ebin), else: :ok) do
      Build.load(modules, ebin)
    end
  end

  defp put_back(ebin_old, ebin) do
    with :ok <- Build.safe_rm_rf(ebin), do: rename(ebin_old, ebin)
  end

  defp rename_if_exists(from, to), do: if(File.exists?(from), do: rename(from, to), else: :ok)

  # Reloads from `ebin` each module whose loaded code isn't that beam.
  defp restore(modules, ebin) do
    stale = Enum.reject(modules, &current?(&1, ebin))

    if stale != [] do
      Build.unload(stale)
      Build.load(stale, ebin)
    end

    :ok
  end

  defp current?(module, ebin) do
    file = String.to_charlist(Path.join(ebin, "#{module}.beam"))

    case {:code.is_loaded(module), :beam_lib.md5(file)} do
      {{:file, _}, {:ok, {^module, md5}}} -> module.module_info(:md5) == md5
      _ -> false
    end
  end

  ## Startup

  # Deletes what an install or a swap cut short left behind.
  defp sweep(dir) do
    for tmp <- Path.wildcard(Path.join(dir, ".tmp-*"), match_dot: true),
        do: Build.safe_rm_rf(tmp)

    :ok
  end

  # {:loaded, entry}, or {:build, entry, job} when it must be compiled first
  defp startup_entry(saved, dir) do
    install_dir = Path.join(dir, Atom.to_string(saved.app))
    ebin = Path.join(install_dir, "ebin")
    tidy(install_dir)

    src =
      if saved.source == :path, do: saved.resolved, else: Path.join(install_dir, "src")

    entry =
      Map.merge(saved, %{modules: [], plugin: nil, failed: nil, building: false, build_error: nil})

    if guarded(fn -> needs_build?(saved.source, src, ebin) end) == true do
      job = %{app: saved.app, src: src, ebin_new: Path.join(install_dir, "ebin.new")}
      {:build, %{entry | building: true}, job}
    else
      {:loaded,
       loaded(%{entry | building: false}, guarded(fn -> load_ebin(ebin, saved.prefix) end))}
    end
  end

  # A swap cut short between its two renames leaves only ebin.old.
  defp tidy(install_dir) do
    ebin = Path.join(install_dir, "ebin")
    ebin_old = Path.join(install_dir, "ebin.old")
    ebin_new = Path.join(install_dir, "ebin.new")

    if not File.dir?(ebin) and File.dir?(ebin_old), do: File.rename(ebin_old, ebin)
    if File.exists?(ebin_new), do: Build.safe_rm_rf(ebin_new)
    :ok
  end

  defp start_builds(state, []), do: state

  # One task, one plugin after another: compiles in this VM don't overlap.
  # Nothing is loaded there; each result comes back as {:startup_built, ...}.
  defp start_builds(state, jobs) do
    server = self()

    task =
      Task.Supervisor.async_nolink(state.task_sup, fn ->
        for job <- jobs,
            do: send(server, {:startup_built, job.app, guarded(fn -> startup_build(job) end)})

        :ok
      end)

    %{state | startup: %{ref: task.ref, pid: task.pid}}
  end

  defp startup_build(%{app: app, src: src, ebin_new: ebin_new}) do
    with :ok <- if(File.dir?(src), do: :ok, else: {:error, "#{src} not found"}),
         {:ok, project} <- read_project(src, app),
         :ok <- Build.safe_rm_rf(ebin_new),
         {:ok, built} <- build(src, ebin_new) do
      {:ok, Map.merge(built, %{ebin_new: ebin_new, supports: project.supports})}
    else
      {:error, _} = error ->
        Code.delete_path(ebin_new)
        Build.safe_rm_rf(ebin_new)
        error
    end
  end

  # Entries still building when the task ended
  defp finish_builds(state, msg) do
    Enum.reduce(state.plugins, state, fn
      {app, %{building: true} = entry}, state ->
        install_dir = install_dir(state, app)
        ebin_new = Path.join(install_dir, "ebin.new")
        Code.delete_path(ebin_new)
        unload_stray([ebin_new], entry.prefix, [])
        Build.safe_rm_rf(ebin_new)
        put_in(state.plugins[app], finish_build(entry, {:error, msg}, install_dir))

      _, state ->
        state
    end)
    |> recompute()
  end

  defp finish_build(entry, {:ok, built}, install_dir) do
    entry = %{entry | building: false}

    case swap(entry, built, install_dir) do
      {:ok, entry} -> entry
      {:error, msg} -> fall_back(entry, msg, install_dir)
      {:failed, msg, _} -> fall_back(entry, msg, install_dir)
    end
  end

  defp finish_build(entry, {:error, msg}, install_dir),
    do: fall_back(%{entry | building: false}, msg, install_dir)

  # The build failed: the last good beams, if any, are loaded instead.
  defp fall_back(entry, msg, install_dir) do
    ebin = Path.join(install_dir, "ebin")

    if beams(ebin) == [] do
      loaded(entry, {:error, msg})
    else
      Logger.warning("beamdash: plugin #{entry.app} not rebuilt, its last build is used: #{msg}")
      loaded(%{entry | build_error: msg}, guarded(fn -> load_ebin(ebin, entry.prefix) end))
    end
  end

  defp loaded(entry, {:ok, %{modules: modules, plugin: plugin, prefix: prefix}}),
    do: %{entry | modules: modules, plugin: plugin, prefix: prefix, failed: nil}

  defp loaded(entry, {:error, msg}) do
    Logger.warning("beamdash: plugin #{entry.app} not loaded: #{msg}")
    %{entry | modules: [], plugin: nil, failed: msg}
  end

  # Runs `fun`; an exception, exit or throw becomes {:error, message}.
  defp guarded(fun) do
    fun.()
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, Exception.format_banner(kind, reason)}
  end

  defp needs_build?(source, src, ebin) do
    cond do
      beams(ebin) == [] ->
        true

      source == :path ->
        sources = [Path.join(src, "mix.exs") | Path.wildcard(Path.join(src, "lib/**/*.ex"))]
        newest(sources) > oldest_beam(ebin)

      true ->
        false
    end
  end

  defp load_ebin(ebin, prefix) do
    modules = for beam <- beams(ebin), do: beam |> Path.basename(".beam") |> String.to_atom()

    with {:ok, prefix} <- entry_prefix(prefix, modules, ebin),
         {:ok, plugin} <- Build.check(modules, prefix, ebin),
         :ok <- Build.load(modules, ebin) do
      {:ok, %{modules: modules, plugin: plugin, prefix: prefix}}
    end
  end

  # The saved entry module, else (an entry saved before it was) the one
  # module whose beam exports __beamdash_plugin__/0.
  defp entry_prefix(_prefix, [], _ebin), do: {:error, "no compiled modules"}

  defp entry_prefix(prefix, _modules, _ebin) when is_atom(prefix) and prefix != nil,
    do: {:ok, prefix}

  defp entry_prefix(nil, modules, ebin) do
    found =
      for module <- modules,
          file = String.to_charlist(Path.join(ebin, "#{module}.beam")),
          {:ok, {_, [exports: exports]}} <- [:beam_lib.chunks(file, [:exports])],
          {:__beamdash_plugin__, 0} in exports,
          do: module

    case found do
      [prefix] -> {:ok, prefix}
      _ -> {:error, "exactly one module in #{ebin} must export __beamdash_plugin__/0"}
    end
  end

  defp beams(ebin), do: Path.wildcard(Path.join(ebin, "*.beam"))

  defp newest(files), do: files |> Enum.map(&mtime/1) |> Enum.max()

  defp oldest_beam(ebin), do: ebin |> beams() |> Enum.map(&mtime/1) |> Enum.min()

  defp mtime(file) do
    case File.stat(file, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> 0
    end
  end

  ## plugins.json

  defp json_path(dir), do: Path.join(dir, "plugins.json")

  # Missing or broken means no plugins; a broken entry is skipped.
  defp read_saved(dir) do
    with {:ok, json} <- File.read(json_path(dir)),
         {:ok, list} when is_list(list) <- Jason.decode(json) do
      list |> Enum.flat_map(&from_json/1) |> Enum.uniq_by(& &1.app)
    else
      _ -> []
    end
  end

  defp from_json(%{"app" => app, "source" => source, "resolved" => resolved} = json)
       when source in ["hex", "git", "path"] and is_binary(resolved) and is_binary(app) do
    with true <- Regex.match?(@app_re, app),
         {:ok, supports} <- supports_from_json(json["supports"]) do
      [
        %{
          app: String.to_atom(app),
          spec_text: to_string_or_nil(json["spec"]),
          source: String.to_existing_atom(source),
          resolved: resolved,
          supports: supports,
          installed_at: to_string_or_nil(json["installed_at"]),
          prefix: prefix_from_json(json["prefix"])
        }
      ]
    else
      _ -> []
    end
  end

  defp from_json(_), do: []

  defp supports_from_json(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn
      %{"app" => app} = s, {:ok, acc} when is_binary(app) ->
        req = s["requirement"]

        if Regex.match?(@app_re, app) and (is_nil(req) or is_binary(req)),
          do: {:cont, {:ok, acc ++ [{String.to_atom(app), req}]}},
          else: {:halt, :error}

      _, _ ->
        {:halt, :error}
    end)
  end

  defp supports_from_json(_), do: :error

  # A plain top-level module name ("HelloPlugin") that isn't beamdash's or
  # Elixir's; anything else is looked up again from the beams.
  defp prefix_from_json(name) when is_binary(name) do
    if Regex.match?(~r/\A[A-Z][A-Za-z0-9_]{0,63}\z/, name) and
         name not in Build.reserved_prefixes(),
       do: Module.concat([name])
  end

  defp prefix_from_json(_), do: nil

  defp to_string_or_nil(value) when is_binary(value), do: value
  defp to_string_or_nil(_), do: nil

  # Written to a temp file then renamed, so a crash never leaves half a file.
  # :ok or {:error, message}.
  defp save(state) do
    json =
      state.plugins
      |> Map.values()
      |> Enum.sort_by(& &1.app)
      |> Enum.map(fn entry ->
        %{
          "app" => Atom.to_string(entry.app),
          "spec" => entry.spec_text,
          "source" => Atom.to_string(entry.source),
          "resolved" => entry.resolved,
          "supports" =>
            for(
              {app, req} <- entry.supports,
              do: %{"app" => Atom.to_string(app), "requirement" => req}
            ),
          "installed_at" => entry.installed_at,
          "prefix" => if(entry.prefix, do: inspect(entry.prefix))
        }
      end)

    path = json_path(state.dir)
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(state.dir),
         :ok <- File.write(tmp, Jason.encode!(json, pretty: true)),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} -> {:error, "could not save #{path}: #{:file.format_error(reason)}"}
    end
  end

  ## Active set

  # Reads the node's running applications in a task; the answer comes back
  # as {:running, node, running}. Beamdash.Apps.running/1, not list/1: that
  # leaves out library applications (no application master), which a plugin
  # may support.
  defp refresh(%{node: node} = state) do
    if state.refresh, do: Process.cancel_timer(state.refresh)
    server = self()

    Task.Supervisor.start_child(state.task_sup, fn ->
      case Apps.running(node) do
        {:ok, running} -> send(server, {:running, node, running})
        _ -> :ok
      end
    end)

    %{state | refresh: Process.send_after(self(), {:refresh, node}, state.refresh_ms)}
  end

  defp recompute(state) do
    statuses = Map.new(state.plugins, fn {app, entry} -> {app, status(entry, state)} end)
    if statuses != state.statuses, do: broadcast(state, :changed)
    %{state | statuses: statuses}
  end

  defp status(%{building: true}, _state), do: :building
  defp status(%{failed: msg}, _state) when is_binary(msg), do: {:failed, msg}
  defp status(entry, state), do: Compat.status(entry.supports, state.running)

  ## Helpers

  defp find(state, app) when is_atom(app), do: state.plugins[app]

  defp find(state, app) when is_binary(app),
    do: Enum.find(Map.values(state.plugins), &(Atom.to_string(&1.app) == app))

  defp install_dir(state, app), do: Path.join(state.dir, Atom.to_string(app))

  # Each of `parts` under `dir` exists and is no symlink: folders, then a
  # regular file.
  defp no_links?(dir, [last]) do
    match?({:ok, %{type: :regular}}, File.lstat(Path.join(dir, last)))
  end

  defp no_links?(dir, [part | rest]) do
    path = Path.join(dir, part)
    match?({:ok, %{type: :directory}}, File.lstat(path)) and no_links?(path, rest)
  end

  defp source_dir(_state, %{source: :path, resolved: path}), do: path
  defp source_dir(state, entry), do: Path.join(install_dir(state, entry.app), "src")

  # Why `app` can't be rebuilt or removed now, or nil.
  defp busy(state, app) do
    cond do
      Map.has_key?(state.rebuilding, app) -> "#{app} is being rebuilt"
      match?(%{building: true}, state.plugins[app]) -> "#{app} is still being built"
      true -> nil
    end
  end

  defp public(entry, state) do
    entry
    |> Map.take([
      :app,
      :spec_text,
      :source,
      :resolved,
      :supports,
      :plugin,
      :modules,
      :build_error
    ])
    |> Map.put(:status, status(entry, state))
  end

  defp broadcast(state, event),
    do: Phoenix.PubSub.broadcast(state.pubsub, @topic, {:beamdash_plugins, event})
end
