defmodule BeamdashWeb.SettingsLive do
  use Phoenix.LiveView
  alias Beamdash.{Format, Jev, Kubectl, LastConnection, Settings, Target}
  alias BeamdashWeb.PluginsSettings

  @impl true
  def mount(_, session, socket) do
    {:ok,
     socket
     |> assign(
       jev_enabled: Settings.jev_enabled?(),
       jev_backend: Jev.backend(),
       auto_reconnect: Settings.auto_reconnect?(),
       saved_connection: saved(),
       browser: nil,
       source_dirs: Settings.source_dirs(),
       source_dir_error: nil,
       source_form: %{"app" => "", "dir" => ""},
       node_apps: node_apps()
     )
     |> assign_kubeconfig_dir(Settings.kubeconfig_dir())
     |> PluginsSettings.mount(session)}
  end

  @doc false
  # called by `BeamdashWeb.Connection` when a plugin is added, changed or removed
  def plugins_changed(socket, _event), do: PluginsSettings.refresh(socket)

  @doc false
  # called by `BeamdashWeb.Connection` when the directory changes in any tab
  def kubeconfig_dir_changed(socket, dir), do: assign_kubeconfig_dir(socket, dir)

  # the input shows `dir` with the home directory as `~`; the status line
  # says how many clusters the connection bar will offer from it.
  defp assign_kubeconfig_dir(socket, dir) do
    status =
      case Kubectl.list_kubeconfigs(dir) do
        {:ok, []} -> {:warn, "No config, .yaml or .yml kubeconfig files in this directory."}
        {:ok, [_]} -> {:ok, "1 cluster found."}
        {:ok, clusters} -> {:ok, "#{length(clusters)} clusters found."}
        {:error, reason} -> {:warn, Format.error(reason)}
      end

    assign(socket, kubeconfig_dir: tilde(dir), kubeconfig_status: status)
  end

  defp tilde(dir) do
    home = Path.expand("~")

    cond do
      dir == home -> "~"
      String.starts_with?(dir, home <> "/") -> "~" <> String.trim_leading(dir, home)
      true -> dir
    end
  end

  # the attached node's applications, suggested for a source folder
  defp node_apps do
    with %{status: :connected, node: node} <- Target.status(),
         {:ok, apps} when is_list(apps) <- Target.rpc(node, :application, :which_applications, []) do
      apps |> Enum.map(&Atom.to_string(elem(&1, 0))) |> Enum.sort()
    else
      _ -> []
    end
  end

  # nil: remembering is off in the configuration
  defp saved, do: if(LastConnection.path(), do: LastConnection.get())

  # The directory browser lists the local filesystem from the server: beamdash
  # runs on this machine, and a browser folder picker never reveals the full path.
  # Opens at `dir`, or its nearest existing parent. `for` is the field the
  # picked directory goes to: `:kubeconfig` or `:source`.
  defp browse(socket, dir, for) do
    dir = existing_dir(Path.expand(dir))

    {subdirs, error} =
      case File.ls(dir) do
        {:ok, names} ->
          {names |> Enum.filter(&File.dir?(Path.join(dir, &1))) |> Enum.sort(), nil}

        {:error, reason} ->
          {[], "Could not list this directory: #{inspect(reason)}"}
      end

    kubeconfigs =
      case for == :kubeconfig && Kubectl.list_kubeconfigs(dir) do
        {:ok, files} -> length(files)
        _ -> 0
      end

    assign(socket,
      browser: %{
        for: for,
        path: dir,
        label: tilde(dir),
        subdirs: subdirs,
        kubeconfigs: kubeconfigs,
        error: error
      }
    )
  end

  defp existing_dir(dir) do
    parent = Path.dirname(dir)
    if File.dir?(dir) or parent == dir, do: dir, else: existing_dir(parent)
  end

  @impl true
  def handle_event("plugin_" <> _ = event, params, socket),
    do: PluginsSettings.handle_event(event, params, socket)

  @impl true
  def handle_event("browse_kubeconfig_dir", _, socket) do
    {:noreply, browse(socket, Settings.kubeconfig_dir(), :kubeconfig)}
  end

  # opens at the folder typed, else the application's saved one, else home
  @impl true
  def handle_event("browse_source_dir", _, socket) do
    %{"app" => app, "dir" => dir} = socket.assigns.source_form

    start =
      cond do
        String.trim(dir) != "" -> dir
        dir = socket.assigns.source_dirs[String.trim(app)] -> dir
        true -> "~"
      end

    {:noreply, browse(socket, start, :source)}
  end

  @impl true
  def handle_event("browse_into", %{"name" => name}, %{assigns: %{browser: %{} = b}} = socket) do
    {:noreply, browse(socket, Path.join(b.path, name), b.for)}
  end

  @impl true
  def handle_event("browse_up", _, %{assigns: %{browser: %{} = b}} = socket) do
    {:noreply, browse(socket, Path.dirname(b.path), b.for)}
  end

  @impl true
  def handle_event("browse_pick", _, %{assigns: %{browser: %{for: :source} = b}} = socket) do
    form = Map.put(socket.assigns.source_form, "dir", tilde(b.path))
    {:noreply, assign(socket, browser: nil, source_form: form)}
  end

  @impl true
  def handle_event("browse_pick", _, %{assigns: %{browser: %{} = b}} = socket) do
    :ok = Settings.put_kubeconfig_dir(b.path)
    {:noreply, socket |> assign(browser: nil) |> assign_kubeconfig_dir(Settings.kubeconfig_dir())}
  end

  @impl true
  def handle_event("browse_close", _, socket), do: {:noreply, assign(socket, browser: nil)}

  @impl true
  def handle_event("set_kubeconfig_dir", %{"kubeconfig_dir" => dir}, socket) do
    dir = String.trim(dir)
    dir = if dir == "", do: Settings.default_kubeconfig_dir(), else: dir
    :ok = Settings.put_kubeconfig_dir(dir)
    {:noreply, assign_kubeconfig_dir(socket, Settings.kubeconfig_dir())}
  end

  @impl true
  def handle_event("reset_kubeconfig_dir", _, socket) do
    :ok = Settings.reset_kubeconfig_dir()
    {:noreply, assign_kubeconfig_dir(socket, Settings.kubeconfig_dir())}
  end

  # what is typed, so a re-render (a picked folder) keeps it
  @impl true
  def handle_event("source_form", %{"app" => app, "dir" => dir}, socket),
    do: {:noreply, assign(socket, source_form: %{"app" => app, "dir" => dir})}

  @impl true
  def handle_event("add_source_dir", %{"app" => app, "dir" => dir}, socket) do
    {app, dir} = {String.trim(app), String.trim(dir)}

    error =
      cond do
        app == "" or dir == "" -> "Enter an application and a folder."
        not File.dir?(Path.expand(dir)) -> "No such folder: #{dir}"
        true -> nil
      end

    form =
      if error == nil do
        :ok = Settings.put_source_dir(app, dir)
        %{"app" => "", "dir" => ""}
      else
        %{"app" => app, "dir" => dir}
      end

    {:noreply,
     assign(socket,
       source_dirs: Settings.source_dirs(),
       source_dir_error: error,
       source_form: form
     )}
  end

  @impl true
  def handle_event("remove_source_dir", %{"app" => app}, socket) do
    :ok = Settings.delete_source_dir(app)
    {:noreply, assign(socket, source_dirs: Settings.source_dirs(), source_dir_error: nil)}
  end

  @impl true
  def handle_event("forget_connection", _, socket) do
    :ok = LastConnection.forget()
    :ok = BeamdashWeb.Connection.forget_typed()

    # empty the connection bar on this page too (other tabs on their next visit)
    socket =
      case socket.assigns[:conn] do
        %{status: :disconnected} = conn ->
          assign(socket, :conn, Map.merge(conn, %{node_input: "", cookie_input: ""}))

        %{} = conn ->
          assign(socket, :conn, Map.put(conn, :cookie_input, ""))

        nil ->
          socket
      end

    {:noreply, assign(socket, saved_connection: saved())}
  end

  @impl true
  def handle_event("toggle_auto_reconnect", _, socket) do
    enabled = not Settings.auto_reconnect?()
    :ok = Settings.put_auto_reconnect(enabled)
    unless enabled, do: Target.stop_reconnect()
    {:noreply, assign(socket, auto_reconnect: enabled)}
  end

  @impl true
  def handle_event("toggle_jev", _, socket) do
    enabled = not Settings.jev_enabled?()
    :ok = Settings.put_jev_enabled(enabled)
    {:noreply, assign(socket, jev_enabled: enabled)}
  end

  def handle_event("set_backend", %{"backend" => value}, socket) do
    case Enum.find(Jev.configured_backends(), &(Atom.to_string(&1) == value)) do
      nil ->
        {:noreply, socket}

      backend ->
        :ok = Settings.put_decision_backend(backend)
        {:noreply, assign(socket, jev_backend: backend)}
    end
  end

  # an install's progress and a rebuild's result
  @impl true
  def handle_info(message, socket), do: PluginsSettings.handle_info(message, socket)

  @impl true
  def render(assigns) do
    ~H"""
    <main class="wrap settings-page">
      <BeamdashWeb.Layouts.header
        active={:settings}
        syntax={@syntax}
        conn={assigns[:conn]}
        ask={assigns[:ask]}
        ask_on={BeamdashWeb.JevSection.show?(assigns[:jev_enabled])}
      />
      <h2>Settings</h2>
      <section class="mem-panel settings-card" aria-labelledby="conn-setting-heading">
        <h3 id="conn-setting-heading">Connection</h3>
        <div class="settings-toggle-row">
          <div>
            <strong>Remembered node and cookie</strong>
            <p class="muted small" id="saved-connection">
              <%= cond do %>
                <% @saved_connection == nil -> %>
                  Remembering is turned off in the configuration.
                <% @saved_connection.node == "" -> %>
                  Nothing saved yet. The node and cookie of the next successful connection
                  fill the connection bar, also after beamdash restarts.
                <% true -> %>
                  <span class="mono">{@saved_connection.node}</span>
                  · {if @saved_connection.cookie == "", do: "no cookie", else: "cookie saved"}.
                  They fill the connection bar, also after beamdash restarts.
              <% end %>
            </p>
          </div>
          <button
            :if={@saved_connection && @saved_connection.node != ""}
            type="button"
            id="forget-connection"
            class="secondary"
            phx-click="forget_connection"
          >
            Forget
          </button>
        </div>
        <p :if={@saved_connection} class="muted small">
          Kept in <span class="mono">{LastConnection.path()}</span>, readable only by you.
        </p>
        <div class="settings-toggle-row">
          <div>
            <strong id="reconnect-setting-label">Reconnect automatically</strong>
            <p id="reconnect-setting-help" class="muted small">
              When the node goes down or its kubectl tunnel fails, connect again the same way:
              after 1, 2, 5 and 10 s, then every 15 s until it works. Ending the connection
              yourself, or connecting to another node, stops it.
            </p>
          </div>
          <button
            type="button"
            id="auto-reconnect"
            role="switch"
            aria-checked={to_string(@auto_reconnect)}
            aria-labelledby="reconnect-setting-label"
            aria-describedby="reconnect-setting-help"
            phx-click="toggle_auto_reconnect"
            class={["settings-switch", @auto_reconnect && "on"]}
          ><span class="settings-switch-knob" aria-hidden="true"></span></button>
          <span class="small" role="status">{if @auto_reconnect, do: "On", else: "Off"}</span>
        </div>
        <form
          id="kubeconfig-dir-form"
          class="settings-toggle-row"
          phx-submit="set_kubeconfig_dir"
        >
          <div>
            <label for="kubeconfig-dir"><strong>Kubeconfig directory</strong></label>
            <p class="muted small" id="kubeconfig-dir-help">
              The kubectl connection offers one cluster per <span class="mono">.yaml</span>
              or <span class="mono">.yml</span>
              file in this directory.
            </p>
            <input
              type="text"
              id="kubeconfig-dir"
              name="kubeconfig_dir"
              class="mono settings-path"
              value={@kubeconfig_dir}
              placeholder="~/.kube"
              autocomplete="off"
              spellcheck="false"
              aria-describedby="kubeconfig-dir-help kubeconfig-dir-status"
            />
            <p
              id="kubeconfig-dir-status"
              role="status"
              class={["small", elem(@kubeconfig_status, 0) == :warn && "error"]}
            >
              {elem(@kubeconfig_status, 1)}
            </p>
          </div>
          <button type="submit">Save</button>
          <button
            type="button"
            id="browse-kubeconfig-dir"
            class="secondary"
            phx-click={
              if @browser && @browser.for == :kubeconfig,
                do: "browse_close",
                else: "browse_kubeconfig_dir"
            }
            aria-expanded={to_string(@browser != nil and @browser.for == :kubeconfig)}
            aria-controls="kubeconfig-browser"
          >
            Browse…
          </button>
          <button
            :if={@kubeconfig_dir != tilde(Settings.default_kubeconfig_dir())}
            type="button"
            id="reset-kubeconfig-dir"
            class="secondary"
            phx-click="reset_kubeconfig_dir"
          >
            Reset
          </button>
        </form>
        <.dir_browser
          :if={@browser && @browser.for == :kubeconfig}
          id="kubeconfig-browser"
          browser={@browser}
          label="Choose kubeconfig directory"
        />
        <p class="muted small">
          Applies at once to the connection bar in every open tab; resets to
          <span class="mono">{tilde(Settings.default_kubeconfig_dir())}</span>
          when beamdash restarts.
        </p>
      </section>
      <section class="mem-panel settings-card" aria-labelledby="source-setting-heading">
        <h3 id="source-setting-heading">Module source</h3>
        <p class="muted small">
          A release (in a Kubernetes pod, say) usually has neither its modules' source files nor
          their debug info. Point an application at a folder with its source on this computer, and
          the Source button shows the matching file from there. It is the file as it is here, which
          may differ from the version the node runs.
        </p>
        <ul :if={@source_dirs != %{}} id="source-dirs" class="settings-list">
          <li :for={{app, dir} <- Enum.sort(@source_dirs)} class="settings-toggle-row">
            <div>
              <strong class="mono">{app}</strong>
              <p class="mono small">{tilde(dir)}</p>
              <p :if={not File.dir?(dir)} class="small error">This folder doesn't exist.</p>
            </div>
            <button
              type="button"
              class="secondary"
              phx-click="remove_source_dir"
              phx-value-app={app}
              aria-label={"Remove the source folder of #{app}"}
            >
              Remove
            </button>
          </li>
        </ul>
        <form
          id="source-dir-form"
          class="settings-toggle-row"
          phx-change="source_form"
          phx-submit="add_source_dir"
        >
          <div>
            <label for="source-app"><strong>Application</strong></label>
            <input
              type="text"
              id="source-app"
              name="app"
              value={@source_form["app"]}
              class="mono"
              list="source-app-options"
              placeholder="my_app"
              autocomplete="off"
              spellcheck="false"
            />
            <datalist id="source-app-options">
              <option :for={app <- @node_apps} value={app} />
            </datalist>
            <label for="source-dir"><strong>Source folder</strong></label>
            <input
              type="text"
              id="source-dir"
              name="dir"
              value={@source_form["dir"]}
              class="mono settings-path"
              placeholder="~/src/my_app"
              autocomplete="off"
              spellcheck="false"
            />
            <p :if={@source_dir_error} role="alert" class="small error">{@source_dir_error}</p>
          </div>
          <button type="submit">Add</button>
          <button
            type="button"
            id="browse-source-dir"
            class="secondary"
            phx-click={
              if @browser && @browser.for == :source, do: "browse_close", else: "browse_source_dir"
            }
            aria-expanded={to_string(@browser != nil and @browser.for == :source)}
            aria-controls="source-browser"
          >
            Browse…
          </button>
        </form>
        <.dir_browser
          :if={@browser && @browser.for == :source}
          id="source-browser"
          browser={@browser}
          label="Choose the source folder"
        />
      </section>
      <section
        :if={Jev.available?()}
        class="mem-panel settings-card"
        aria-labelledby="jev-setting-heading"
      >
        <h3 id="jev-setting-heading">Suggestions model</h3>
        <div :if={length(Jev.configured_backends()) > 1} class="settings-toggle-row">
          <div>
            <strong id="jev-backend-label">Model</strong>
            <p class="muted small">
              Jev is TypeSafe's hosted model; Kev a self-hosted one with the same API.
              Saved for the next start; the next request goes to the one chosen.
            </p>
          </div>
          <div class="seg" role="radiogroup" aria-labelledby="jev-backend-label">
            <button
              :for={b <- Jev.configured_backends()}
              type="button"
              role="radio"
              aria-checked={to_string(@jev_backend == b)}
              class={["seg-btn", @jev_backend == b && "active"]}
              phx-click="set_backend"
              phx-value-backend={b}
            >
              {Jev.name(b)}
            </button>
          </div>
        </div>
        <div class="settings-toggle-row">
          <div>
            <strong id="jev-setting-label">Enable {Jev.name(@jev_backend)} analysis</strong>
            <p id="jev-setting-help" class="muted small">
              Use {Jev.name(@jev_backend)} for investigation suggestions on the Processes and GC pages.
            </p>
          </div>
          <button
            type="button"
            role="switch"
            aria-checked={to_string(@jev_enabled)}
            aria-labelledby="jev-setting-label"
            aria-describedby="jev-setting-help"
            phx-click="toggle_jev"
            class={["settings-switch", @jev_enabled && "on"]}
          ><span class="settings-switch-knob" aria-hidden="true"></span></button>
          <span class="small" role="status">{if @jev_enabled, do: "Enabled", else: "Disabled"}</span>
        </div>
        <p :if={@jev_backend == :jev} class="guide small">
          When on, clicking Analyze in a process panel (Processes or GC tab) sends
          measurements computed from that process to TypeSafe's Jev model: trends, shares,
          status, OTP kind and rank on the node. Never names, pids, modules, stacks, messages
          or state. Nothing is sent while you only browse. TypeSafe's documentation does not
          state how long it keeps requests; calls may be charged.
        </p>
        <p :if={@jev_backend == :kev} class="guide small">
          When on, clicking Analyze in a process panel (Processes or GC tab) sends
          measurements computed from that process to the Kev server at {Jev.endpoint(:kev)}:
          trends, shares, status, OTP kind and rank on the node. Never names, pids, modules,
          stacks, messages or state. Nothing is sent while you only browse.
        </p>
        <p class="muted small">
          Applies at once to every open tab. Until switched here, it is on only when a model
          is configured; the switch resets when beamdash restarts. Turning it off cancels
          pending results; requests already sent cannot be recalled.
        </p>
        <p class="muted small">
          {cond do
            @jev_backend == :kev ->
              "Kev server #{Jev.endpoint(:kev)} · model #{Jev.model(:kev)}."

            Jev.configured?(:jev) ->
              "API key configured · model #{Jev.model(:jev)}."

            true ->
              "No API key. Set TYPESAFE_API_KEY in the environment and restart beamdash to use Jev."
          end}
          <span :if={not Jev.configured?(:kev)}>
            Set KEV_URL to a Kev server to try Kev instead.
          </span>
        </p>
      </section>
      <PluginsSettings.card
        plugins={@plugins}
        dir={@plugins_dir}
        spec={@plugin_spec}
        install={@plugin_install}
        confirm_remove={@plugin_confirm_remove}
        rebuilding={@plugin_rebuilding}
        notes={@plugin_notes}
        notice={@plugin_notice}
      />
    </main>
    """
  end

  attr :id, :string, required: true
  attr :browser, :map, required: true
  attr :label, :string, required: true

  # the directory browser, under the field it fills (`@browser.for`)
  defp dir_browser(assigns) do
    ~H"""
    <div id={@id} class="dir-browser" role="group" aria-label={@label}>
      <div class="dir-browser-head">
        <button
          type="button"
          id="browse-up"
          class="secondary"
          phx-click="browse_up"
          disabled={Path.dirname(@browser.path) == @browser.path}
          aria-label="Parent directory"
        >
          ↑ Up
        </button>
        <span class="mono dir-browser-path">{@browser.label}</span>
        <span :if={@browser.for == :kubeconfig} class="muted small" role="status">
          {case @browser.kubeconfigs do
            0 -> "no kubeconfig files here"
            1 -> "1 kubeconfig file here"
            n -> "#{n} kubeconfig files here"
          end}
        </span>
      </div>
      <p :if={@browser.error} class="small error">{@browser.error}</p>
      <ul class="dir-browser-list">
        <li :for={name <- @browser.subdirs}>
          <button
            type="button"
            class="dir-browser-entry mono"
            phx-click="browse_into"
            phx-value-name={name}
          >
            📁 {name}
          </button>
        </li>
        <li :if={@browser.subdirs == [] and !@browser.error} class="muted small">
          No subdirectories.
        </li>
      </ul>
      <div class="dir-browser-actions">
        <button type="button" id="browse-pick" phx-click="browse_pick">
          {if @browser.for == :source, do: "Use this folder", else: "Use this directory"}
        </button>
        <button type="button" class="secondary" phx-click="browse_close">Cancel</button>
      </div>
    </div>
    """
  end
end
