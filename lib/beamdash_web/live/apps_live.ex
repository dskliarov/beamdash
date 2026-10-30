defmodule BeamdashWeb.AppsLive do
  @moduledoc """
  Observer's Applications tab: the running applications on the left, the
  selected one's process tree on the right (from its application master,
  following links). Clicking a process selects it; Process info opens it
  on the Processes tab. Refreshed every 5 s.

  The selected application's tabs: its process tree, its details, and the
  main page of each active plugin that supports it (`@conn.plugins`, see
  `BeamdashWeb.Connection`), embedded as on the plugin's own page.
  """
  use Phoenix.LiveView

  alias Beamdash.{Apps, Format, Plugins, Target}
  alias BeamdashWeb.SourceTabs

  @refresh_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    %{status: status, node: node} = Target.status()

    socket =
      assign(socket,
        status: status,
        node: node,
        apps: [],
        app: nil,
        tree: nil,
        info: nil,
        view: :tree,
        plugin_css?: false,
        selected: nil,
        proc: nil,
        error: nil
      )
      |> SourceTabs.init()

    if connected?(socket) do
      :ok = Target.subscribe()
      Process.send_after(self(), :refresh, @refresh_ms)
      {:ok, load(socket)}
    else
      {:ok, socket}
    end
  end

  # ?app= opens that application
  @impl true
  def handle_params(%{"app" => app}, _uri, socket) do
    case Enum.find(socket.assigns.apps, &(Atom.to_string(&1.name) == app)) do
      %{name: name} -> {:noreply, socket |> assign(app: name, selected: nil) |> load_tree()}
      nil -> {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  defp load(%{assigns: %{status: :connected, node: node}} = socket) do
    case Apps.list(node) do
      {:ok, apps} ->
        # as Observer: the first application listed (the latest started)
        app =
          if Enum.any?(apps, &(&1.name == socket.assigns.app)),
            do: socket.assigns.app,
            else: apps |> List.first() |> then(&(&1 && &1.name))

        socket |> assign(apps: apps, app: app, error: nil) |> load_tree()

      {:error, reason} ->
        assign(socket, error: Format.error(reason))
    end
  end

  defp load(socket), do: socket

  defp load_tree(%{assigns: %{app: nil}} = socket), do: assign(socket, tree: nil, info: nil)

  # the tree and the application's details, refreshed together
  defp load_tree(%{assigns: %{node: node, app: app}} = socket) do
    with {:ok, tree} <- Apps.tree(node, app),
         {:ok, info} <- Apps.info(node, app) do
      socket |> assign(tree: tree, info: info, error: nil) |> load_proc()
    else
      {:error, reason} -> assign(socket, error: Format.error(reason))
    end
  end

  # the selected process's details and module: `:exited` once it is gone
  defp load_proc(%{assigns: %{selected: nil}} = socket), do: assign(socket, proc: nil)

  defp load_proc(%{assigns: %{node: node, selected: pid}} = socket) do
    case Apps.process(node, pid) do
      {:ok, nil} -> assign(socket, proc: :exited)
      {:ok, proc} -> assign(socket, proc: proc)
      {:error, _} -> socket
    end
  end

  @impl true
  def handle_event("app", %{"app" => app}, socket) do
    name = Enum.find_value(socket.assigns.apps, &(Atom.to_string(&1.name) == app && &1.name))
    {:noreply, socket |> assign(app: name, selected: nil) |> load_tree()}
  end

  def handle_event("select", %{"pid" => pid}, socket) do
    pid = Target.parse_pid(pid, socket.assigns.node)
    selected = if socket.assigns.selected == pid, do: nil, else: pid
    {:noreply, socket |> assign(selected: selected) |> load_proc()}
  end

  # the tab stays as it is when another application is picked (a plugin's
  # tab while the plugin supports that one too); picking one leaves a source
  def handle_event("view", %{"view" => view}, socket) when view in ~w(tree details),
    do: {:noreply, assign(socket, view: String.to_existing_atom(view), source_tab: nil)}

  def handle_event("view", %{"view" => "plugin:" <> app}, socket) do
    case Enum.find(plugin_tabs(socket.assigns), &(Atom.to_string(&1.app) == app)) do
      nil ->
        {:noreply, socket}

      plugin ->
        {:noreply,
         assign(socket, view: {:plugin, plugin.app}, plugin_css?: css?(plugin), source_tab: nil)}
    end
  end

  # the selected process's module: its Source button opens it in a tab (see
  # BeamdashWeb.SourceTabs); only that module is taken from the browser
  def handle_event(event, params, socket)
      when event in ~w(open_source source_tab close_source) do
    modules =
      case socket.assigns.proc do
        %{module: %{module: mod}} -> [mod]
        _ -> []
      end

    {:noreply, SourceTabs.event(event, params, socket, modules)}
  end

  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, load(socket)}
  end

  def handle_info({:beamdash_target, {:connected, node}}, socket),
    do:
      {:noreply,
       socket |> assign(status: :connected, node: node, app: nil) |> SourceTabs.init() |> load()}

  def handle_info({:beamdash_target, {:disconnected, _}}, socket),
    do:
      {:noreply,
       socket
       |> SourceTabs.init()
       |> assign(
         status: :disconnected,
         apps: [],
         app: nil,
         tree: nil,
         info: nil,
         selected: nil,
         proc: nil
       )}

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Rendering

  @impl true
  def render(assigns) do
    plugins = plugin_tabs(assigns)

    # a plugin's tab that no longer applies (another application, the plugin
    # gone) shows the tree
    tab =
      case {assigns.source_tab, assigns.view} do
        {mod, _} when mod != nil ->
          {:source, mod}

        {_, {:plugin, app}} ->
          if Enum.any?(plugins, &(&1.app == app)), do: assigns.view, else: :tree

        {_, view} ->
          view
      end

    assigns =
      assign(assigns,
        current: Enum.find(assigns.apps, &(&1.name == assigns.app)),
        names: if(assigns.tree, do: names(assigns.tree.root), else: %{}),
        plugins: plugins,
        tab: tab
      )

    ~H"""
    <main class="wrap apps-page">
      <BeamdashWeb.Layouts.header
        active={:apps}
        syntax={@syntax}
        conn={assigns[:conn]}
        ask={assigns[:ask]}
        ask_on={BeamdashWeb.JevSection.ask_on?(assigns[:jev_enabled])}
      />

      <p :if={@status != :connected} class="help">
        Not connected: enter a node above and click Connect.
      </p>
      <p :if={@error} class="error">{@error}</p>

      <div :if={@status == :connected} class="apps-layout">
        <aside class="apps-list" aria-label="Applications">
          <div class="apps-list-head">
            <strong>Applications</strong>
            <span class="muted small">{length(@apps)}</span>
            <button class="secondary small-btn" phx-click="refresh" title="Refresh">↻</button>
          </div>
          <ul>
            <li
              :for={a <- Enum.sort_by(@apps, &Atom.to_string(&1.name))}
              class={a.name == @app && "selected"}
            >
              <a
                href="#"
                phx-click="app"
                phx-value-app={a.name}
                title={"#{a.description} (#{a.vsn})"}
              >
                {a.name} <span class="muted small">{a.vsn}</span>
              </a>
            </li>
          </ul>
        </aside>

        <section class="apps-main">
          <div :if={@current} class="apps-head">
            <h2>{@current.name}</h2>
            <span class="muted">{@current.vsn} · {@current.description}</span>
          </div>

          <nav :if={@current} class="seg apps-tabs" role="tablist" aria-label="Application view">
            <button
              :for={{view, label} <- [tree: "Process tree", details: "Details"]}
              type="button"
              role="tab"
              aria-selected={to_string(@tab == view)}
              class={["seg-btn", @tab == view && "active"]}
              phx-click="view"
              phx-value-view={view}
            >
              {label}
              <span :if={view == :tree and @tree} class="muted">
                {Format.number(@tree.count)}
              </span>
            </button>
            <button
              :for={p <- @plugins}
              type="button"
              role="tab"
              aria-selected={to_string(@tab == {:plugin, p.app})}
              class={["seg-btn", @tab == {:plugin, p.app} && "active"]}
              phx-click="view"
              phx-value-view={"plugin:#{p.app}"}
              title={"The #{p.name} plugin's #{p.main.label} page"}
            >
              {p.main.label} <span class="muted">{p.name}</span>
            </button>
            <SourceTabs.source_buttons sources={@sources} current={@source_tab} syntax={@syntax} />
          </nav>

          <SourceTabs.panel
            :if={@current}
            sources={@sources}
            current={@source_tab}
            syntax={@syntax}
          />

          <div
            :for={p <- @plugins}
            :if={@current && @tab == {:plugin, p.app}}
            class="apps-panel apps-plugin"
            role="tabpanel"
          >
            <link :if={@plugin_css?} rel="stylesheet" href={"/plugins/#{p.app}/plugin.css"} />
            <%!-- only once connected, as on the plugin's own page --%>
            <%= if connected?(@socket) do %>
              {live_render(@socket, p.main.module,
                id: "apps-plugin-#{p.app}-#{p.main.slug}-#{@syntax}",
                session: BeamdashWeb.PluginLive.page_session(p.app, p.module, @syntax)
              )}
            <% else %>
              <div class="plugin-loading muted small">Loading {p.main.label}…</div>
            <% end %>
          </div>

          <div :if={@current && @tab == :details} class="apps-panel" role="tabpanel">
            <.details :if={@info} info={@info} apps={@apps} syntax={@syntax} />
            <p :if={@info == nil} class="muted">
              This application isn't loaded any more.
            </p>
          </div>

          <div :if={@current && @tab == :tree} class="apps-panel" role="tabpanel">
            <p :if={@tree} class="muted small">
              {Format.number(@tree.count)} processes · as Observer: from the application master, following links · refreshed every 5 s
            </p>

            <div :if={@selected} class="apps-selected" role="status">
              <span class="mono">
                {pid_label(@selected, @names, @syntax)}
              </span>
              <.link
                navigate={"/?pid=" <> URI.encode_www_form(Format.pid(@selected, :erlang))}
                class="btn-link small-btn"
                title="Open its details on the Processes tab"
              >
                Process info ↗
              </.link>
              <button
                class="secondary small-btn"
                phx-click="select"
                phx-value-pid={Format.pid(@selected, :erlang)}
              >
                ×
              </button>
            </div>
            <.proc_details :if={@selected && @proc} proc={@proc} syntax={@syntax} />

            <p :if={@tree == nil} class="muted">
              This application has no processes (a library application) or has just stopped.
            </p>
            <BeamdashWeb.AppChart.chart
              :if={@tree}
              root={@tree.root}
              selected={@selected}
              syntax={@syntax}
            />
            <p
              :if={@tree && Enum.any?(Map.values(@names), &(&1.also != []))}
              class="muted small apps-legend"
            >
              <span class="xlink-key" aria-hidden="true"></span>
              a secondary link: a process also linked to one drawn elsewhere in the tree.
            </p>
          </div>
        </section>
      </div>
    </main>
    """
  end

  attr :proc, :any, required: true, doc: "`Beamdash.Apps.process/2`, or `:exited`"
  attr :syntax, :atom, default: :erlang

  # The selected process: what it runs and holds, and the module that
  # implements it, with links to trace or profile that module.
  defp proc_details(%{proc: :exited} = assigns) do
    ~H"""
    <p class="apps-proc muted small" role="status">The process has exited.</p>
    """
  end

  defp proc_details(assigns) do
    assigns = assign(assigns, p: assigns.proc.process, m: assigns.proc.module)

    ~H"""
    <div class="apps-proc">
      <dl class="apps-details">
        <dt>Initial call</dt>
        <dd class="mono">{Format.mfa(@p.initial_call, @syntax)}</dd>
        <dt>Current function</dt>
        <dd class="mono">{Format.mfa(@p.current_function, @syntax)}</dd>
        <dt>Status</dt>
        <dd>{@p.status}</dd>
        <dt>Message queue</dt>
        <dd class={@p.mailbox.length > 0 && "warn"}>{Format.number(@p.mailbox.length)}</dd>
        <dt>Memory</dt>
        <dd>{Format.bytes(@p.memory.total)}</dd>
        <dt>Reductions</dt>
        <dd>{Format.number(@p.reductions)}</dd>
        <dt>Links</dt>
        <dd>{length(@p.links)}</dd>
        <dt :if={@p.trap_exit}>Traps exits</dt>
        <dd :if={@p.trap_exit}>yes</dd>
      </dl>

      <BeamdashWeb.ModuleInfo.section :if={@m} module={@m} syntax={@syntax} />
    </div>
    """
  end

  # the active plugins that support the selected application
  defp plugin_tabs(%{app: nil}), do: []

  defp plugin_tabs(assigns) do
    plugins = (assigns[:conn] && assigns.conn[:plugins]) || []
    Enum.filter(plugins, &(assigns.app in Map.get(&1, :supports, [])))
  end

  defp css?(plugin) do
    match?({:ok, _}, Plugins.css_path(plugin.app))
  catch
    :exit, _ -> false
  end

  attr :info, :map, required: true, doc: "`Beamdash.Apps.info/2`"
  attr :apps, :list, required: true
  attr :syntax, :atom, default: :erlang

  # What application:get_all_key/1 and get_all_env/1 say of the application.
  defp details(assigns) do
    ~H"""
    <dl class="apps-details">
      <dt>Started</dt>
      <dd>{if @info.start_type, do: @info.start_type, else: "loaded, not started"}</dd>
      <dt :if={@info.mod != []}>Callback</dt>
      <dd :if={@info.mod != []} class="mono">{callback(@info.mod, @syntax)}</dd>
      <dt>Depends on</dt>
      <dd><.app_names names={@info.applications} apps={@apps} syntax={@syntax} /></dd>
      <dt :if={@info.optional_applications != []}>Optional</dt>
      <dd :if={@info.optional_applications != []}>
        <.app_names names={@info.optional_applications} apps={@apps} syntax={@syntax} />
      </dd>
      <dt :if={@info.included_applications != []}>Includes</dt>
      <dd :if={@info.included_applications != []}>
        <.app_names names={@info.included_applications} apps={@apps} syntax={@syntax} />
      </dd>
      <dt>Needed by</dt>
      <dd><.app_names names={@info.needed_by} apps={@apps} syntax={@syntax} /></dd>
      <dt>Modules</dt>
      <dd>{Format.number(@info.modules)}</dd>
      <dt :if={@info.registered != []}>Registered</dt>
      <dd :if={@info.registered != []} class="mono">
        {Enum.map_join(@info.registered, ", ", &Format.name(&1, @syntax))}
      </dd>
      <dt :if={@info.start_phases}>Start phases</dt>
      <dd :if={@info.start_phases} class="mono">{Format.term(@info.start_phases, @syntax)}</dd>
      <dt :if={@info.id != ""}>Id</dt>
      <dd :if={@info.id != ""}>{@info.id}</dd>
      <dt :if={@info.path}>Path</dt>
      <dd :if={@info.path} class="mono">{@info.path}</dd>
    </dl>
    <details
      id="apps-env"
      class="apps-env"
      phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["open"])}
    >
      <summary>Environment <span class="muted small">{length(@info.env)}</span></summary>
      <p :if={@info.env == []} class="muted small">No environment keys are set.</p>
      <table :if={@info.env != []} class="apps-env-table">
        <tr :for={{key, value} <- @info.env}>
          <th class="mono">{Format.name(key, @syntax)}</th>
          <td class="mono">{Format.term(value, @syntax, 400)}</td>
        </tr>
      </table>
    </details>
    """
  end

  attr :names, :list, required: true
  attr :apps, :list, required: true
  attr :syntax, :atom, default: :erlang

  # application names; the ones with a process tree open it
  defp app_names(assigns) do
    assigns =
      assign(assigns, shown: MapSet.new(assigns.apps, & &1.name), last: length(assigns.names) - 1)

    ~H"""
    <span :if={@names == []} class="muted">none</span>
    <span :for={{name, i} <- Enum.with_index(@names)} class="mono"><a
      :if={MapSet.member?(@shown, name)}
      href="#"
      phx-click="app"
      phx-value-app={name}
    >{Format.name(name, @syntax)}</a><span :if={not MapSet.member?(@shown, name)}>{Format.name(name, @syntax)}</span>{if i <
                                                                                                                           @last,
                                                                                                                         do:
                                                                                                                           ", "}</span>
    """
  end

  defp callback({mod, args}, syntax),
    do: "#{Format.name(mod, syntax)} #{Format.term(args, syntax)}"

  defp callback(other, syntax), do: Format.term(other, syntax)

  # pid => text, for secondary links and the selection
  defp names(node),
    do: Enum.reduce(node.children, %{node.pid => node}, &Map.merge(&2, names(&1)))

  defp pid_label(pid, names, syntax) do
    case names[pid] do
      %{name: n} when not is_nil(n) -> "#{Format.name(n, syntax)} #{Format.pid(pid, syntax)}"
      %{label: l} when not is_nil(l) -> "#{l} #{Format.pid(pid, syntax)}"
      _ -> Format.pid(pid, syntax)
    end
  end
end
