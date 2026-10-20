defmodule ExberlyWeb.AppsLive do
  @moduledoc """
  Observer's Applications tab: the running applications on the left, the
  selected one's process tree on the right (from its application master,
  following links). Clicking a process selects it; Process info opens it
  on the Processes tab. Refreshed every 5 s.
  """
  use Phoenix.LiveView

  alias Exberly.{Apps, Format, Target}

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
        selected: nil,
        error: nil
      )

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

  defp load_tree(%{assigns: %{app: nil}} = socket), do: assign(socket, tree: nil)

  defp load_tree(%{assigns: %{node: node, app: app}} = socket) do
    case Apps.tree(node, app) do
      {:ok, tree} -> assign(socket, tree: tree, error: nil)
      {:error, reason} -> assign(socket, error: Format.error(reason))
    end
  end

  @impl true
  def handle_event("app", %{"app" => app}, socket) do
    name = Enum.find_value(socket.assigns.apps, &(Atom.to_string(&1.name) == app && &1.name))
    {:noreply, socket |> assign(app: name, selected: nil) |> load_tree()}
  end

  def handle_event("select", %{"pid" => pid}, socket) do
    pid = parse_pid(pid)
    selected = if socket.assigns.selected == pid, do: nil, else: pid
    {:noreply, assign(socket, selected: selected)}
  end

  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, load(socket)}
  end

  def handle_info({:exberly_target, {:connected, node}}, socket),
    do: {:noreply, socket |> assign(status: :connected, node: node, app: nil) |> load()}

  def handle_info({:exberly_target, {:disconnected, _}}, socket),
    do:
      {:noreply,
       assign(socket, status: :disconnected, apps: [], app: nil, tree: nil, selected: nil)}

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Rendering

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        current: Enum.find(assigns.apps, &(&1.name == assigns.app)),
        names: if(assigns.tree, do: names(assigns.tree.root), else: %{})
      )

    ~H"""
    <main class="wrap apps-page">
      <ExberlyWeb.Layouts.header
        active={:apps}
        syntax={@syntax}
        conn={assigns[:conn]}
        ask={assigns[:ask]}
        ask_on={ExberlyWeb.JevSection.show?(assigns[:jev_enabled])}
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
            <span :if={@tree} class="muted small">
              {Format.number(@tree.count)} processes · as Observer: from the application master, following links · refreshed every 5 s
            </span>
          </div>

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

          <p :if={@current && @tree == nil} class="muted">
            This application has no processes (a library application) or has just stopped.
          </p>
          <ExberlyWeb.AppChart.chart
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
        </section>
      </div>
    </main>
    """
  end

  # pids arrive as this VM writes them (<N.x.y>)
  defp parse_pid(string) do
    if Regex.match?(~r/^<\d+\.\d+\.\d+>$/, string),
      do: :erlang.list_to_pid(String.to_charlist(string))
  end

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
