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
       auto_reconnect: Settings.auto_reconnect?(),
       saved_connection: saved(),
       browser: nil
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

  # nil: remembering is off in the configuration
  defp saved, do: if(LastConnection.path(), do: LastConnection.get())

  # The directory browser lists the local filesystem from the server: beamdash
  # runs on this machine, and a browser folder picker never reveals the full path.
  # Opens at `dir`, or its nearest existing parent.
  defp browse(socket, dir) do
    dir = existing_dir(Path.expand(dir))

    {subdirs, error} =
      case File.ls(dir) do
        {:ok, names} ->
          {names |> Enum.filter(&File.dir?(Path.join(dir, &1))) |> Enum.sort(), nil}

        {:error, reason} ->
          {[], "Could not list this directory: #{inspect(reason)}"}
      end

    kubeconfigs =
      case Kubectl.list_kubeconfigs(dir) do
        {:ok, files} -> length(files)
        {:error, _} -> 0
      end

    assign(socket,
      browser: %{
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
    {:noreply, browse(socket, Settings.kubeconfig_dir())}
  end

  @impl true
  def handle_event("browse_into", %{"name" => name}, %{assigns: %{browser: %{} = b}} = socket) do
    {:noreply, browse(socket, Path.join(b.path, name))}
  end

  @impl true
  def handle_event("browse_up", _, %{assigns: %{browser: %{} = b}} = socket) do
    {:noreply, browse(socket, Path.dirname(b.path))}
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
            phx-click={if @browser, do: "browse_close", else: "browse_kubeconfig_dir"}
            aria-expanded={to_string(@browser != nil)}
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
        <div
          :if={@browser}
          id="kubeconfig-browser"
          class="dir-browser"
          role="group"
          aria-label="Choose kubeconfig directory"
        >
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
            <span class="muted small" role="status">
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
              Use this directory
            </button>
            <button type="button" class="secondary" phx-click="browse_close">Cancel</button>
          </div>
        </div>
        <p class="muted small">
          Applies at once to the connection bar in every open tab; resets to
          <span class="mono">{tilde(Settings.default_kubeconfig_dir())}</span>
          when beamdash restarts.
        </p>
      </section>
      <section
        :if={Jev.available?()}
        class="mem-panel settings-card"
        aria-labelledby="jev-setting-heading"
      >
        <h3 id="jev-setting-heading">Jev</h3>
        <div class="settings-toggle-row">
          <div>
            <strong id="jev-setting-label">Enable Jev analysis</strong>
            <p id="jev-setting-help" class="muted small">
              Use Jev for investigation suggestions on the Processes and GC pages.
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
        <p class="guide small">
          When on, clicking Analyze in a process panel (Processes or GC tab) sends
          measurements computed from that process to TypeSafe's Jev model: trends, shares,
          status, OTP kind and rank on the node. Never names, pids, modules, stacks, messages
          or state. Nothing is sent while you only browse. TypeSafe's documentation does not
          state how long it keeps requests; calls may be charged.
        </p>
        <p class="muted small">
          Applies at once to every open tab. Until switched here, Jev is on only when an API
          key is configured; the switch resets when beamdash restarts. Turning it off cancels
          pending results; requests already sent cannot be recalled.
        </p>
        <p class="muted small">
          {if Jev.configured?(),
            do: "API key configured · model #{Jev.model()}.",
            else:
              "No API key. Set TYPESAFE_API_KEY in the environment and restart beamdash to use Jev."}
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
end
