defmodule BeamdashWeb.PluginLive do
  @moduledoc """
  `/plugins/:plugin/:page`: beamdash's header with a plugin's page embedded
  through `live_render/3`. The page runs in its own process, so a crash
  there only takes down its region.

  When the page can't be shown it says why: no such page, the plugin waits
  for its application, or the node runs a version it doesn't support. It
  looks again on `{:beamdash_plugins, :changed}` (from
  `BeamdashWeb.Connection`, through `plugins_changed/2`), and says "Plugin
  removed" when the plugin goes.

  Session seams for tests: `"plugins_server"` (default `Beamdash.Plugins`)
  and `"target"`, passed on to the page.
  """
  use Phoenix.LiveView

  alias Beamdash.Plugins
  alias Beamdash.Plugins.Compat

  @impl true
  def mount(%{"plugin" => app, "page" => slug}, session, socket) do
    {:ok,
     socket
     |> assign(
       app: app,
       slug: slug,
       plugins_server: session["plugins_server"] || Plugins,
       target: session["target"],
       removed: false,
       remounting: false
     )
     |> look_up()}
  end

  @doc false
  # called by `BeamdashWeb.Connection` when the plugins change
  def plugins_changed(socket, {:removed, app}) do
    if to_string(app) == socket.assigns.app,
      do: assign(socket, removed: true, result: {:error, :removed}, page_module: nil),
      else: socket
  end

  # A removed plugin's page says so until the plugin is back (installed
  # again while the page is open).
  def plugins_changed(%{assigns: %{removed: true}} = socket, _event) do
    case look_up(socket) do
      %{assigns: %{result: {:ok, _}}} = socket -> assign(socket, removed: false)
      _ -> socket
    end
  end

  def plugins_changed(socket, _event), do: look_up(socket)

  @doc false
  # called by `BeamdashWeb.Syntax`. The plugin page got the syntax in its
  # session, so it is mounted again: one render without it, then one with
  # it (its container id stays "plugin-<app>-<slug>").
  def syntax_changed(%{assigns: %{result: {:ok, _}}} = socket) do
    send(self(), :beamdash_plugin_remount)

    socket
    |> assign(page_session: Map.put(socket.assigns.page_session, "syntax", socket.assigns.syntax))
    |> assign(remounting: true)
  end

  def syntax_changed(socket), do: socket

  @impl true
  def handle_info(:beamdash_plugin_remount, socket),
    do: {:noreply, assign(socket, remounting: false)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp look_up(%{assigns: a} = socket) do
    result = call(fn -> Plugins.page(a.plugins_server, a.app, a.slug) end, {:error, :not_found})

    case result do
      {:ok, %{app: app, module: module, plugin: plugin, page: page}} ->
        session =
          %{"plugin_app" => app, "plugin_module" => module, "syntax" => a[:syntax] || :erlang}
          |> then(&if(a.target, do: Map.put(&1, "target", a.target), else: &1))

        css? = match?({:ok, _}, call(fn -> Plugins.css_path(a.plugins_server, app) end, :error))

        assign(socket,
          result: result,
          plugin_name: plugin.name,
          page_label: page.label,
          page_module: page.module,
          page_session: session,
          css?: css?
        )

      {:error, _} ->
        entry =
          call(fn -> Plugins.list(a.plugins_server) end, [])
          |> Enum.find(&(to_string(&1.app) == a.app))

        assign(socket,
          result: result,
          plugin_name: entry && entry.plugin && entry.plugin.name,
          supports: (entry && entry.supports) || [],
          page_module: nil
        )
    end
  end

  defp call(fun, default) do
    fun.()
  catch
    :exit, _ -> default
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="wrap plugin-page">
      <BeamdashWeb.Layouts.header
        active={{:plugin, @app, @slug}}
        syntax={@syntax}
        conn={assigns[:conn]}
        ask={assigns[:ask]}
        ask_on={BeamdashWeb.JevSection.show?(assigns[:jev_enabled])}
      />
      <%= case @result do %>
        <% {:ok, _} -> %>
          <link :if={@css?} rel="stylesheet" href={"/plugins/#{@app}/plugin.css"} />
          <%!--
            Only once connected: on the static render the plugin's mount and
            render would run in the HTTP request, and a plugin that raises
            would take beamdash's page down with it.
          --%>
          <%= if connected?(@socket) and not @remounting do %>
            {live_render(@socket, @page_module, id: "plugin-#{@app}-#{@slug}", session: @page_session)}
          <% else %>
            <div id={"plugin-#{@app}-#{@slug}-loading"} class="plugin-loading muted small">
              Loading {@page_label}…
            </div>
          <% end %>
        <% {:error, :removed} -> %>
          <section class="mem-panel plugin-message" role="status">
            <h2>Plugin removed</h2>
            <p class="muted">
              {@plugin_name || @app} was removed. Plugins are managed in <a href="/settings">Settings</a>.
            </p>
          </section>
        <% {:error, :waiting} -> %>
          <section class="mem-panel plugin-message" role="status">
            <h2>{@plugin_name || @app}</h2>
            <p>
              {@plugin_name || @app} needs {needs(@supports)} running on the attached node.
            </p>
          </section>
        <% {:error, {:incompatible, app, vsn, req}} -> %>
          <section class="mem-panel plugin-message" role="status">
            <h2>{@plugin_name || @app}</h2>
            <p>{Compat.reason({:incompatible, app, vsn, req})}.</p>
          </section>
        <% {:error, :building} -> %>
          <section class="mem-panel plugin-message" role="status">
            <h2>{@app}</h2>
            <p class="muted">{@app} is still being built. The page opens when it is ready.</p>
          </section>
        <% {:error, _} -> %>
          <section class="mem-panel plugin-message" role="status">
            <h2>No such plugin page</h2>
            <p class="muted">
              Installed plugins and their status are in <a href="/settings">Settings</a>.
            </p>
          </section>
      <% end %>
    </main>
    """
  end

  defp needs([]), do: "its application"

  defp needs(supports) do
    Enum.map_join(supports, " or ", fn
      {app, nil} -> to_string(app)
      {app, req} -> "#{app} (#{req})"
    end)
  end
end
