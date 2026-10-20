defmodule ExberlyWeb.SettingsLive do
  use Phoenix.LiveView
  alias Exberly.{Jev, LastConnection, Settings}

  @impl true
  def mount(_, _, socket) do
    {:ok, assign(socket, jev_enabled: Settings.jev_enabled?(), saved_connection: saved())}
  end

  # nil: remembering is off in the configuration
  defp saved, do: if(LastConnection.path(), do: LastConnection.get())

  @impl true
  def handle_event("forget_connection", _, socket) do
    :ok = LastConnection.forget()
    :ok = ExberlyWeb.Connection.forget_typed()

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
  def handle_event("toggle_jev", _, socket) do
    enabled = not Settings.jev_enabled?()
    :ok = Settings.put_jev_enabled(enabled)
    {:noreply, assign(socket, jev_enabled: enabled)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="wrap settings-page">
      <ExberlyWeb.Layouts.header
        active={:settings}
        syntax={@syntax}
        conn={assigns[:conn]}
        ask={assigns[:ask]}
        ask_on={ExberlyWeb.JevSection.show?(assigns[:jev_enabled])}
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
                  fill the connection bar, also after exberly restarts.
                <% true -> %>
                  <span class="mono">{@saved_connection.node}</span>
                  · {if @saved_connection.cookie == "", do: "no cookie", else: "cookie saved"}.
                  They fill the connection bar, also after exberly restarts.
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
          key is configured; the switch resets when exberly restarts. Turning it off cancels
          pending results; requests already sent cannot be recalled.
        </p>
        <p class="muted small">
          {if Jev.configured?(),
            do: "API key configured · model #{Jev.model()}.",
            else:
              "No API key. Set TYPESAFE_API_KEY in the environment and restart exberly to use Jev."}
        </p>
      </section>
    </main>
    """
  end
end
