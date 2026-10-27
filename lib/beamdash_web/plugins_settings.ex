defmodule BeamdashWeb.PluginsSettings do
  @moduledoc """
  The Plugins card of `BeamdashWeb.SettingsLive`: the installed plugins with
  Remove (confirmed in the page) and, for path plugins, Rebuild, then the
  form that adds one.

  `mount/2`, `handle_event/3`, `handle_info/2` and `refresh/1` work on the
  Settings socket; their assigns are prefixed `plugin`. The session key
  `"plugins_server"` names the `Beamdash.Plugins` server (tests pass their
  own).
  """
  use Phoenix.Component

  alias Beamdash.Plugins
  alias Beamdash.Plugins.Build

  @examples [
    {"Hex", ~s|{:riak_core_plugin, "0.0.1"}|},
    {"Git",
     ~s|{:riak_core_plugin, git: "https://github.com/dskliarov/beamdash-riak-core-plugin", tag: "0.0.1"}|},
    {"Path", ~s|{:riak_core_plugin, path: "~/projects/elixir/beamdash-riak-core-plugin"}|}
  ]

  @down "the plugin registry is not answering; try again"

  @steps %{
    checking: "Checking…",
    fetching: "Fetching…",
    compiling: "Compiling…",
    loading: "Loading…"
  }

  ## On the Settings socket

  def mount(socket, session) do
    server = session["plugins_server"] || Plugins

    socket
    |> assign(
      plugins_server: server,
      plugins_dir: call(fn -> Plugins.dir(server) end, Build.plugins_dir()),
      plugin_spec: "",
      plugin_install: nil,
      plugin_confirm_remove: nil,
      plugin_rebuilding: %{},
      plugin_notes: %{},
      plugin_notice: nil
    )
    |> refresh()
  end

  @doc "Reads the list again."
  def refresh(socket),
    do: assign(socket, plugins: call(fn -> Plugins.list(socket.assigns.plugins_server) end, []))

  def handle_event("plugin_add", %{"spec" => text}, socket) do
    text = String.trim(text)

    case call(fn -> Plugins.install(socket.assigns.plugins_server, text) end, {:error, @down}) do
      {:ok, ref} ->
        {:noreply, install(socket, %{ref: ref, step: :checking, result: nil}, text)}

      # a second Add while this page's install runs: that one stays shown
      {:error, _} when socket.assigns.plugin_install.result == nil ->
        {:noreply, socket}

      {:error, msg} ->
        {:noreply, install(socket, %{ref: nil, step: nil, result: {:error, msg}}, text)}
    end
  end

  def handle_event("plugin_remove", %{"app" => app}, socket),
    do: {:noreply, assign(socket, plugin_confirm_remove: app, plugin_notice: nil)}

  def handle_event("plugin_remove_cancel", _params, socket),
    do: {:noreply, assign(socket, plugin_confirm_remove: nil)}

  # only the Remove that asked (a second click finds nothing to confirm)
  def handle_event("plugin_remove_confirm", %{"app" => app}, socket)
      when app != socket.assigns.plugin_confirm_remove,
      do: {:noreply, socket}

  def handle_event("plugin_remove_confirm", %{"app" => app}, socket) do
    notice =
      case call(fn -> Plugins.remove(socket.assigns.plugins_server, app) end, :down) do
        :ok -> {:ok, "Removed #{app}"}
        {:error, msg} -> {:error, msg}
        :down -> {:error, "#{app} is not removed: #{@down}"}
      end

    {:noreply,
     socket
     |> assign(
       plugin_confirm_remove: nil,
       plugin_notice: notice,
       plugin_notes: Map.delete(socket.assigns.plugin_notes, app)
     )
     |> refresh()}
  end

  # The compile runs in the caller (see Plugins.rebuild/2): a task, so the
  # page keeps answering.
  def handle_event("plugin_rebuild", %{"app" => app}, socket) do
    if app in Map.values(socket.assigns.plugin_rebuilding) do
      {:noreply, socket}
    else
      server = socket.assigns.plugins_server

      task =
        Task.Supervisor.async_nolink(Beamdash.Plugins.TaskSup, fn ->
          Plugins.rebuild(server, app)
        end)

      {:noreply,
       assign(socket,
         plugin_rebuilding: Map.put(socket.assigns.plugin_rebuilding, task.ref, app),
         plugin_notes: Map.delete(socket.assigns.plugin_notes, app)
       )}
    end
  end

  def handle_info({:beamdash_plugins, {:install, ref, step}}, socket) do
    case socket.assigns.plugin_install do
      %{ref: ^ref} = install ->
        {:noreply, assign(socket, plugin_install: %{install | step: step})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:beamdash_plugins, {:installed, ref, app}}, socket) do
    case socket.assigns.plugin_install do
      %{ref: ^ref} = install ->
        socket = refresh(socket)
        result = {:ok, "Installed #{name(find(socket.assigns.plugins, app)) || app}"}

        {:noreply,
         assign(socket, plugin_install: %{install | result: result, step: nil}, plugin_spec: "")}

      _ ->
        {:noreply, refresh(socket)}
    end
  end

  def handle_info({:beamdash_plugins, {:install_failed, ref, msg}}, socket) do
    case socket.assigns.plugin_install do
      %{ref: ^ref} = install ->
        {:noreply, assign(socket, plugin_install: %{install | result: {:error, msg}, step: nil})}

      _ ->
        {:noreply, socket}
    end
  end

  # a rebuild's result
  def handle_info({ref, result}, socket) when is_reference(ref) do
    case Map.pop(socket.assigns.plugin_rebuilding, ref) do
      {nil, _} ->
        {:noreply, socket}

      {app, rebuilding} ->
        Process.demonitor(ref, [:flush])
        socket = refresh(socket)

        note =
          case result do
            :ok -> {:ok, "Rebuilt #{name(find(socket.assigns.plugins, app)) || app}"}
            {:error, msg} -> {:error, msg}
          end

        {:noreply, rebuilt(socket, rebuilding, app, note)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
    case Map.pop(socket.assigns.plugin_rebuilding, ref) do
      {nil, _} ->
        {:noreply, socket}

      {app, rebuilding} ->
        note = {:error, "the rebuild crashed: #{inspect(reason)}"}
        {:noreply, socket |> refresh() |> rebuilt(rebuilding, app, note)}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp install(socket, install, text),
    do: assign(socket, plugin_install: install, plugin_spec: text, plugin_notice: nil)

  defp rebuilt(socket, rebuilding, app, note) do
    assign(socket,
      plugin_rebuilding: rebuilding,
      plugin_notes: Map.put(socket.assigns.plugin_notes, app, note)
    )
  end

  defp find(plugins, app), do: Enum.find(plugins, &(to_string(&1.app) == to_string(app)))

  defp name(nil), do: nil
  defp name(%{plugin: %{name: name}}), do: name
  defp name(%{app: app}), do: to_string(app)

  # the registry's answer, or `default` when it isn't there
  defp call(fun, default) do
    fun.()
  catch
    :exit, _ -> default
  end

  ## The card

  attr :plugins, :list, required: true, doc: "`Beamdash.Plugins.list/1`"
  attr :dir, :string, required: true, doc: "the plugins dir"
  attr :spec, :string, default: "", doc: "the text in the Add field"
  attr :install, :map, default: nil, doc: "%{ref, step, result} of the last install"
  attr :confirm_remove, :string, default: nil, doc: "the app whose Remove asks to confirm"
  attr :rebuilding, :map, default: %{}, doc: "task ref => app of the rebuilds running"
  attr :notes, :map, default: %{}, doc: "app => {:ok | :error, message} under its row"
  attr :notice, :any, default: nil, doc: "{:ok | :error, message} above the list"

  def card(assigns) do
    assigns =
      assign(assigns,
        examples: @examples,
        rebuilding_apps: Map.values(assigns.rebuilding),
        installing: match?(%{result: nil}, assigns.install)
      )

    ~H"""
    <section
      class="mem-panel settings-card plugins-card"
      id="plugins-card"
      aria-labelledby="plugins-setting-heading"
    >
      <h3 id="plugins-setting-heading">Plugins</h3>
      <p
        :if={@notice}
        role="status"
        class={["small", elem(@notice, 0) == :error && "error"]}
        id="plugins-notice"
      >
        {elem(@notice, 1)}
      </p>
      <p :if={@plugins == []} class="muted small">No plugins installed.</p>
      <ul :if={@plugins != []} class="plugin-list">
        <li :for={p <- @plugins} id={"plugin-#{p.app}"} class="plugin-row">
          <div class="plugin-row-main">
            <div class="plugin-row-head">
              <strong class="plugin-name">{name(p)}</strong>
              <span class="mono small muted">{p.app}</span>
              <span class={"plugin-badge plugin-badge-#{p.source}"}>{p.source}</span>
              <span class="mono small" title={to_string(p.resolved)}>{resolved(p)}</span>
            </div>
            <div class="mono small muted plugin-spec">{p.spec_text}</div>
            <div class="small">
              Supports
              <span :for={{app, req} <- p.supports} class="mono plugin-supports">
                {app}{if req, do: " #{req}"}
              </span>
              <span :if={p.supports == []} class="muted">no application</span>
            </div>
            <div class={["small", "plugin-status", status_class(p.status)]} role="status">
              {status_text(p)}
            </div>
            <p :if={p.build_error} class="small notice plugin-build-error">
              The last good build is loaded: rebuilding it failed.
            </p>
            <pre :if={p.build_error} class="plugin-output">{p.build_error}</pre>
            <%= case @notes[to_string(p.app)] do %>
              <% {:ok, msg} -> %>
                <p class="small" role="status">{msg}</p>
              <% {:error, msg} -> %>
                <pre class="plugin-output error" role="alert">{msg}</pre>
              <% nil -> %>
            <% end %>
            <div :if={@confirm_remove == to_string(p.app)} class="plugin-confirm" role="alert">
              <p class="small">
                Remove {name(p)}?
                <%= if p.source == :path do %>
                  Only its compiled files in
                  <span class="mono">{Path.join(@dir, to_string(p.app))}</span>
                  are deleted. Your folder <span class="mono">{p.resolved}</span>
                  is not touched.
                <% else %>
                  This deletes <span class="mono">{Path.join(@dir, to_string(p.app))}</span>,
                  with the source beamdash fetched.
                <% end %>
              </p>
              <button
                type="button"
                class="danger"
                phx-click="plugin_remove_confirm"
                phx-value-app={p.app}
              >
                Confirm remove
              </button>
              <button type="button" class="secondary" phx-click="plugin_remove_cancel">
                Cancel
              </button>
            </div>
          </div>
          <div :if={@confirm_remove != to_string(p.app)} class="plugin-row-actions">
            <button
              :if={p.source == :path}
              type="button"
              class="secondary"
              phx-click="plugin_rebuild"
              phx-value-app={p.app}
              disabled={to_string(p.app) in @rebuilding_apps}
            >
              {if to_string(p.app) in @rebuilding_apps, do: "Rebuilding…", else: "Rebuild"}
            </button>
            <button type="button" class="secondary" phx-click="plugin_remove" phx-value-app={p.app}>
              Remove
            </button>
          </div>
        </li>
      </ul>

      <form id="plugin-add-form" class="plugin-add" phx-submit="plugin_add">
        <label for="plugin-spec"><strong>Mix dependency</strong></label>
        <div class="plugin-add-row">
          <input
            type="text"
            id="plugin-spec"
            name="spec"
            class="mono"
            value={@spec}
            placeholder={~s|{:riak_core_plugin, "~> 0.1"}|}
            autocomplete="off"
            spellcheck="false"
            aria-describedby="plugin-examples plugin-warning"
          />
          <button type="submit" disabled={@installing}>Add</button>
        </div>
        <dl id="plugin-examples" class="plugin-examples small">
          <%= for {kind, text} <- @examples do %>
            <dt class="muted">{kind}</dt>
            <dd class="mono">{text}</dd>
          <% end %>
        </dl>
        <p id="plugin-warning" class="small notice">
          A plugin runs inside beamdash with full access to the nodes you connect to, and compiling it runs its code inside beamdash. Add only plugins you trust.
        </p>
        <div :if={@install} id="plugin-install" role="status" aria-live="polite">
          <%= case @install do %>
            <% %{result: {:ok, msg}} -> %>
              <p class="small">{msg}</p>
            <% %{result: {:error, msg}} -> %>
              <pre class="plugin-output error">{msg}</pre>
            <% %{step: step} -> %>
              <p class="small muted">{step_text(step)}</p>
          <% end %>
        </div>
      </form>
      <p class="muted small">
        Plugins are kept in <span class="mono">{@dir}</span>.
      </p>
    </section>
    """
  end

  defp step_text(step), do: Map.get(@steps, step, "Working…")

  defp resolved(%{source: :git, resolved: commit}), do: String.slice(commit, 0, 7)
  defp resolved(%{resolved: resolved}), do: resolved

  @doc false
  def status_text(%{status: :active}), do: "active"
  def status_text(%{status: :building}), do: "building…"
  def status_text(%{status: :waiting, supports: []}), do: "waiting"

  def status_text(%{status: :waiting, supports: supports}),
    do: "waiting for " <> Enum.map_join(supports, " or ", fn {app, _} -> to_string(app) end)

  def status_text(%{status: {:incompatible, app, vsn, req}}),
    do: "#{app} #{vsn} running, needs #{req}"

  def status_text(%{status: {:failed, msg}}), do: "failed: #{msg}"

  defp status_class(:active), do: "plugin-status-active"
  defp status_class({:failed, _}), do: "error"
  defp status_class(_), do: "muted"
end
