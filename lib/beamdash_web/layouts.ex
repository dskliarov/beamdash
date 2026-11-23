defmodule BeamdashWeb.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>beamdash</title>
        <link rel="icon" href="data:," />
        <link rel="stylesheet" href="/assets/app.css" />
        <script defer src="/deps/phoenix/phoenix.js">
        </script>
        <script defer src="/deps/phoenix_live_view/phoenix_live_view.js">
        </script>
        <%!-- Highlight.js 11.9.0 (BSD-3-Clause), vendored: the module source view --%>
        <script defer src="/assets/vendor/highlight/highlight.min.js">
        </script>
        <script defer src="/assets/vendor/highlight/erlang.min.js">
        </script>
        <script defer src="/assets/vendor/highlight/elixir.min.js">
        </script>
        <script defer src="/assets/source_editor.js">
        </script>
        <script defer src="/assets/follow_bottom.js">
        </script>
        <script defer src="/assets/console_completion.js">
        </script>
        <script defer src="/assets/notebook_files.js">
        </script>
        <script defer src="/assets/vendor/codemirror/editor.js">
        </script>
        <script defer src="/assets/module_editor.js">
        </script>
        <script defer src="/assets/logs_scroll.js">
        </script>
        <script defer src="/assets/kino_chart.js">
        </script>
        <script defer src="/assets/app.js">
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  defp kube_method_label do
    if Application.get_env(:beamdash, :has_k8s, false), do: "Kubernetes", else: "kubectl"
  end

  defp saved_title(%{"kind" => "kubectl"} = entry), do: entry["pod"]
  defp saved_title(entry), do: entry["node"]

  defp saved_meta(%{"kind" => "kubectl"} = entry) do
    [Path.rootname(Path.basename(entry["kubeconfig"])), entry["namespace"], entry["container"]]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp saved_meta(_entry), do: "direct"

  defp shown_connections(%{connections: connections, server: server} = conn) do
    if conn[:only_selected],
      do: Enum.filter(connections, &(&1.server == server)),
      else: connections
  end

  attr :target, :map, required: true, doc: "a Kubernetes pod: cluster, namespace and pod name"

  defp kube_labels(assigns) do
    ~H"""
    <span class="kube-target">
      <span class="kube-part">
        <span class="kube-key">cluster</span>
        <strong>{@target.cluster}</strong>
      </span>
      <span class="kube-part">
        <span class="kube-key">namespace</span>
        <strong>{@target.namespace}</strong>
      </span>
      <span class="kube-part">
        <span class="kube-key">pod</span>
        <strong>{@target.pod}</strong>
      </span>
    </span>
    """
  end

  attr :label, :string, required: true, doc: "the node the button disconnects, for its label"

  attr :server, :string,
    default: nil,
    doc: "the connection's key; nil disconnects the session's own"

  defp disconnect_x(assigns) do
    ~H"""
    <button
      type="button"
      class="icon-btn conn-disconnect"
      phx-click="disconnect"
      phx-value-server={@server}
      aria-label={"Disconnect #{@label}"}
      title="Disconnect"
    >
      <svg viewBox="0 0 16 16" width="10" height="10" aria-hidden="true">
        <path
          d="M3 3l10 10M13 3L3 13"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
        />
      </svg>
    </button>
    """
  end

  # saved is most recent first, so the groups are too
  defp saved_groups(saved) do
    groups = Enum.group_by(saved, &saved_app/1)
    saved |> Enum.map(&saved_app/1) |> Enum.uniq() |> Enum.map(&{&1, groups[&1]})
  end

  defp saved_app(entry), do: entry["app"] || ""

  defp unconnected_saved(conn) do
    connected =
      for c <- Map.get(conn, :connections, []),
          c.status == :connected,
          into: MapSet.new(),
          do: to_string(c.node)

    Enum.reject(Map.get(conn, :saved, []), &MapSet.member?(connected, &1["node"]))
  end

  attr :progress, :map, required: true, doc: "a step: label, command (or nil), elapsed seconds"

  defp progress_line(assigns) do
    ~H"""
    <p class="conn-progress muted small" role="status">
      <span class="dot dot-wait" aria-hidden="true"></span>
      <span>{@progress.label} · {@progress.elapsed}s</span>
      <code :if={@progress.command} class="conn-command" title={@progress.command}>{@progress.command}</code>
    </p>
    """
  end

  attr :active, :any, required: true, doc: "a tab's key, or {:plugin, app, slug}"
  attr :syntax, :atom, required: true
  attr :conn, :map, default: nil, doc: "from BeamdashWeb.Connection; nil hides the bar"
  attr :ask, :map, default: nil, doc: "from BeamdashWeb.Ask; nil hides the box"
  attr :ask_on, :boolean, default: false, doc: "Jev on and configured"
  attr :working, :string, default: nil, doc: "what the page is waiting for from the node"

  @doc """
  The page header on every tab: tabs and syntax switch, then, on a line
  of its own aligned right, the connection: node and cookie with Connect
  when disconnected, the node with Disconnect when connected. The node's
  OTP release, process count and memory follow below it.
  """
  def header(assigns) do
    ~H"""
    <header class="bar">
      <h1>beamdash</h1>
      <.nav
        active={@active}
        syntax={@syntax}
        plugins={(@conn && @conn[:plugins]) || []}
        compare={multiple_connections?(@conn)}
      />

      <div :if={@conn} class="conn-line">
        <div
          :if={@conn.status != :connected && @conn[:reconnecting]}
          class="reconnecting"
          role="status"
        >
          <span class="dot dot-wait" aria-hidden="true"></span>
          <span>
            Reconnecting to <strong>{@conn.reconnecting.node}</strong>
            · try {@conn.reconnecting.attempt} at {Calendar.strftime(
              @conn.reconnecting.next_at,
              "%H:%M:%S"
            )} UTC<span :if={@conn.reconnecting.error} class="muted small">
              · last try: {Beamdash.Format.error(@conn.reconnecting.error)}
            </span>
          </span>
          <button type="button" class="secondary small-btn" phx-click="stop_reconnect">Stop</button>
        </div>
        <div
          :if={@conn.status != :connected or (@conn[:multiple] && @conn[:panel])}
          class={["connect-panel", @conn.status == :connected && "below"]}
        >
          <button
            :if={@conn.status == :connected}
            type="button"
            class="icon-btn conn-close"
            phx-click="toggle_panel"
            aria-label="Close connect"
            title="Close"
          >
            ×
          </button>
          <div class="seg method-switch" role="group" aria-label="Connection method">
            <button
              type="button"
              class={["seg-btn", Map.get(@conn, :method, :direct) == :direct && "active"]}
              aria-pressed={to_string(Map.get(@conn, :method, :direct) == :direct)}
              phx-click="set_conn_method"
              phx-value-method="direct"
            >
              Direct
            </button>
            <button
              type="button"
              class={["seg-btn", Map.get(@conn, :method, :direct) == :kubectl && "active"]}
              aria-pressed={to_string(Map.get(@conn, :method, :direct) == :kubectl)}
              phx-click="set_conn_method"
              phx-value-method="kubectl"
            >
              {kube_method_label()}
            </button>
            <button
              type="button"
              class={["seg-btn", Map.get(@conn, :method, :direct) == :saved && "active"]}
              aria-pressed={to_string(Map.get(@conn, :method, :direct) == :saved)}
              phx-click="set_conn_method"
              phx-value-method="saved"
            >
              Saved
            </button>
          </div>

          <div :if={Map.get(@conn, :method, :direct) == :saved} class="conn-rows">
            <% available = unconnected_saved(@conn) %>
            <div
              :if={available != []}
              id="saved-connections"
              class="saved-connections"
              aria-label="Saved connections"
            >
              <section :for={{app, entries} <- saved_groups(available)} class="saved-group">
                <h3 class="saved-app muted small">
                  {if app == "", do: "Unknown application", else: app}
                </h3>
                <ul class="saved-group-list">
                  <li :for={entry <- entries} class="saved-connection">
                    <button
                      type="button"
                      class="secondary small-btn saved-connect"
                      phx-click="connect_saved"
                      phx-value-id={entry["id"]}
                      disabled={not is_nil(@conn[:connecting])}
                    >
                      <span class="saved-name">{saved_title(entry)}</span>
                      <span class="saved-meta">{saved_meta(entry)}</span>
                    </button>
                    <button
                      type="button"
                      class="icon-btn delete-saved"
                      phx-click="forget_saved"
                      phx-value-id={entry["id"]}
                      aria-label={"Delete #{saved_title(entry)} (#{saved_meta(entry)})"}
                      title="Delete"
                    >
                      <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
                        <path
                          d="M3 4h10M6.5 4V2.5h3V4M4.5 4l.6 9.5h5.8l.6-9.5"
                          fill="none"
                          stroke="currentColor"
                          stroke-width="1.4"
                          stroke-linecap="round"
                          stroke-linejoin="round"
                        />
                      </svg>
                    </button>
                  </li>
                </ul>
              </section>
            </div>
            <p :if={Map.get(@conn, :saved, []) == []} class="conn-hint muted small">
              No saved connections yet. A connection that works is kept here.
            </p>
            <p
              :if={Map.get(@conn, :saved, []) != [] and available == []}
              class="conn-hint muted small"
            >
              Every saved connection is already connected.
            </p>
          </div>

          <form
            :if={Map.get(@conn, :method, :direct) == :direct}
            id="connect-form"
            phx-submit="connect"
            class="conn-rows"
          >
            <div class="conn-row">
              <label class="field-label" for="conn-node">Node</label>
              <input
                id="conn-node"
                class="wide"
                name="node"
                value={@conn.node_input}
                placeholder="node@host"
                required
                autocomplete="off"
              />
            </div>
            <div class="conn-row">
              <label class="field-label" for="conn-cookie">Cookie</label>
              <input
                id="conn-cookie"
                name="cookie"
                type="password"
                value={Map.get(@conn, :cookie_input, "")}
                placeholder="optional"
                autocomplete="off"
              />
              <button type="submit" phx-disable-with="Connecting…">Connect</button>
            </div>
          </form>

          <div :if={Map.get(@conn, :method, :direct) == :kubectl} class="conn-rows">
            <form
              :if={Map.get(@conn, :kube_clusters, []) != []}
              id="select-kube-cluster-form"
              phx-change="select_kube_cluster"
              class="conn-row"
            >
              <label class="field-label" for="kube-cluster">Cluster</label>
              <select
                id="kube-cluster"
                class="wide"
                name="cluster"
                disabled={not is_nil(@conn[:connecting])}
              >
                <option
                  :for={c <- @conn.kube_clusters}
                  value={c.path}
                  selected={c.path == @conn.kube_cluster}
                >
                  {c.name}
                </option>
              </select>
            </form>
            <p :if={Map.get(@conn, :kube_clusters, []) == []} class="conn-hint muted small">
              No kubeconfig files found under <span class="mono">{Map.get(@conn, :kube_dir, "~/.kube")}</span>.
              <span :if={@conn[:kube_cluster_error]}>{@conn.kube_cluster_error}.</span>
              The directory can be changed in <a href="/settings">Settings</a>.
            </p>

            <form
              :if={Map.get(@conn, :kube_clusters, []) != []}
              id="list-kube-pods-form"
              phx-submit="list_kube_pods"
              class="conn-row"
            >
              <label class="field-label" for="kube-namespace">Namespace</label>
              <div
                id="namespace-combobox"
                class="combobox"
                phx-hook="NamespaceCombobox"
                data-options={Jason.encode!(Map.get(@conn, :kube_namespaces, []))}
              >
                <input
                  id="kube-namespace"
                  name="namespace"
                  value={Map.get(@conn, :kube_namespace, "")}
                  placeholder="namespace"
                  required
                  autocomplete="off"
                  role="combobox"
                  aria-autocomplete="list"
                  aria-expanded="false"
                  aria-controls="namespace-options"
                />
                <ul
                  id="namespace-options"
                  class="combobox-list"
                  role="listbox"
                  phx-update="ignore"
                  hidden
                >
                </ul>
              </div>
              <button
                type="submit"
                class="secondary"
                phx-disable-with="Listing…"
                disabled={Map.get(@conn, :kube_pods_listing, false) or not is_nil(@conn[:connecting])}
              >
                List pods
              </button>
            </form>

            <form
              :if={Map.get(@conn, :kube_pods)}
              id="select-kube-pod-form"
              phx-change="select_kube_pod"
              class="conn-row"
            >
              <input type="hidden" name="namespace" value={Map.get(@conn, :kube_namespace, "")} />
              <label class="field-label" for="kube-pod">Pod</label>
              <select
                id="kube-pod"
                name="pod"
                class="wide"
                disabled={@conn.kube_pods == []}
              >
                <option :for={p <- @conn.kube_pods} value={p} selected={p == @conn.kube_pod}>
                  {p}
                </option>
              </select>
            </form>
            <p :if={@conn[:kube_pods] == []} class="conn-hint muted small">
              No pods found in this namespace.
            </p>

            <form
              :if={Map.get(@conn, :kube_containers) && length(@conn.kube_containers) > 1}
              id="select-kube-container-form"
              phx-change="select_kube_container"
              class="conn-row"
            >
              <input type="hidden" name="namespace" value={Map.get(@conn, :kube_namespace, "")} />
              <input type="hidden" name="pod" value={Map.get(@conn, :kube_pod, "")} />
              <label class="field-label" for="kube-container">Container</label>
              <select id="kube-container" class="wide" name="container">
                <option
                  :for={c <- @conn.kube_containers}
                  value={c}
                  selected={c == @conn.kube_container}
                >
                  {c}
                </option>
              </select>
            </form>

            <form
              :if={Map.get(@conn, :kube_binaries)}
              id="connect-kubectl-form"
              phx-submit="connect_kubectl"
              phx-change="select_kube_binary"
              class="conn-row"
            >
              <input type="hidden" name="namespace" value={Map.get(@conn, :kube_namespace, "")} />
              <input type="hidden" name="pod" value={Map.get(@conn, :kube_pod, "")} />
              <input type="hidden" name="container" value={Map.get(@conn, :kube_container, "")} />
              <label class="field-label" for="kube-binary">Binary</label>
              <select id="kube-binary" name="binary" disabled={@conn.kube_binaries == []}>
                <option
                  :for={bin <- @conn.kube_binaries}
                  value={bin}
                  selected={bin == @conn.kube_binary}
                >
                  {bin}
                </option>
              </select>
              <button
                type="submit"
                phx-disable-with="Connecting…"
                disabled={@conn.kube_binaries == [] or not is_nil(@conn[:connecting])}
              >
                {if @conn[:connecting], do: "Connecting…", else: "Connect"}
              </button>
            </form>
            <p :if={@conn[:kube_binaries] == []} class="conn-hint muted small">
              No release binaries found in this pod{if @conn[:kube_container],
                do: " (container #{@conn.kube_container})"}.
            </p>
          </div>
        </div>

        <div
          :if={@conn.status == :connected or length(Map.get(@conn, :connections, [])) > 1}
          class="connected"
        >
          <p :if={@working} id="working" class="working muted small" role="status" aria-live="polite">
            {@working}…
          </p>
          <span
            :if={length(Map.get(@conn, :connections, [])) <= 1}
            class="dot"
            aria-hidden="true"
          ></span>
          <div :if={length(Map.get(@conn, :connections, [])) <= 1} class="connected-single">
            <span class="connected-name">
              <.kube_labels :if={@conn[:kube_target]} target={@conn.kube_target} />
              <strong>{@conn.node}</strong>
              <.disconnect_x label={@conn.node} />
            </span>
            <div :if={@conn[:multiple]} class="conn-actions">
              <button
                type="button"
                class="secondary small-btn conn-action"
                phx-click="toggle_panel"
                aria-expanded={to_string(@conn[:panel] == true)}
              >
                {if @conn[:panel], do: "Hide connect", else: "Add connection"}
              </button>
            </div>
          </div>
          <ul
            :if={length(Map.get(@conn, :connections, [])) > 1}
            id="connected-nodes"
            class="connected-nodes"
            aria-label="Connected nodes"
          >
            <li
              :for={c <- shown_connections(@conn)}
              class={["connected-node", c.server == @conn.server && "selected"]}
            >
              <a
                href={select_href(c.node)}
                class="connected-label connected-select"
                aria-current={if c.server == @conn.server, do: "true"}
              >
                <span class={["dot", c.status != :connected && "dot-wait"]} aria-hidden="true"></span>
                <span class="connected-name">
                  <.kube_labels :if={c[:kube_target]} target={c.kube_target} />
                  <strong>{c.node}</strong>
                </span>
              </a>
              <.disconnect_x label={c.node} server={Beamdash.Connections.key(c.server)} />
            </li>
            <li :if={@conn[:multiple]} class="connected-node connected-add">
              <div class="conn-actions">
                <button
                  type="button"
                  class="secondary small-btn conn-action"
                  phx-click="toggle_panel"
                  aria-expanded={to_string(@conn[:panel] == true)}
                >
                  {if @conn[:panel], do: "Hide connect", else: "Add connection"}
                </button>
                <button
                  type="button"
                  class="secondary small-btn conn-action"
                  phx-click="toggle_only_selected"
                  aria-pressed={to_string(@conn[:only_selected] == true)}
                >
                  {if @conn[:only_selected], do: "Show all", else: "Show selected only"}
                </button>
              </div>
            </li>
          </ul>
        </div>
      </div>
    </header>
    <div
      :if={
        @conn &&
          (@conn[:connecting] ||
             (@conn.status != :connected && @conn[:kube_progress]) ||
             (@conn[:connecting_others] || %{}) != %{})
      }
      class="conn-progress-slot"
    >
      <div class="conn-progress-overlay">
        <.progress_line :if={@conn[:connecting]} progress={@conn[:connecting]} />
        <.progress_line
          :if={@conn.status != :connected && @conn[:kube_progress]}
          progress={@conn[:kube_progress]}
        />
        <.progress_line
          :for={{_server, step} <- @conn[:connecting_others] || %{}}
          progress={step}
        />
      </div>
    </div>
    <p :if={@conn && @conn.error} class="error conn-error" role="alert">{@conn.error}</p>
    <p :if={@conn && @conn[:notice]} class="muted small conn-notice" role="status">{@conn.notice}</p>
    <div
      :if={
        (@ask && @ask_on) || (@conn && @conn.status == :connected) ||
          (@conn && length(Map.get(@conn, :connections, [])) > 1)
      }
      class="subbar"
    >
      <div :if={@ask && @ask_on} class="ask">
        <form id="ask-form" phx-submit="ask" role="search">
          <input
            type="search"
            name="ask_q"
            value={@ask.query}
            placeholder="Ask beamdash… e.g. who is leaking binaries?"
            autocomplete="off"
            aria-label="Ask beamdash"
            title={"#{Beamdash.Jev.name()} picks the view that answers your question; only the question is sent."}
            disabled={@ask.busy != nil}
          />
          <button type="submit" class="small-btn" disabled={@ask.busy != nil}>
            {if @ask.busy, do: "Asking…", else: "Ask"}
          </button>
        </form>
        <div :if={@ask.options != [] or @ask.error} class="ask-results" role="status">
          <span :if={@ask.error} class="error small">{@ask.error}</span>
          <span :if={@ask.options != []} class="muted small">{Beamdash.Jev.name()} suggests:</span>
          <.link :for={o <- @ask.options} navigate={o.path} class="ask-option">
            {o.label} <span class="muted">{round(o.probability * 100)}%</span>
          </.link>
          <button type="button" class="secondary small-btn" phx-click="ask_close" aria-label="Close">
            ×
          </button>
        </div>
      </div>
      <div class="node-meta">
        <div :if={@conn && @conn.status == :connected} class="node-info muted small">
          <%= if @conn.info do %>
            <span>OTP {@conn.info.otp_release}</span>
            <span>{Beamdash.Format.number(@conn.info.process_count)} processes</span>
            <span>{Beamdash.Format.bytes(@conn.info.memory_total)} memory</span>
          <% else %>
            <span>Reading node info…</span>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp select_href(node),
    do: "/connections/select?" <> URI.encode_query(%{"node" => to_string(node)})

  # The tabs in three groups: the node, its processes, tracing. Each: path,
  # active key, short label, full name, shortcut key (g then the key).
  @groups [
    {"Node",
     [
       {"/system", :system, "System", "System", "s"},
       {"/nodes", :nodes, "Nodes", "Nodes", "n"},
       {"/load", :load, "Load", "Load Charts", "l"},
       {"/apps", :apps, "Apps", "Applications", "a"},
       {"/modules", :modules, "Modules", "Modules", "u"},
       {"/console", :console, "Console", "Remote console", "e"},
       {"/memory", :memory, "Memory", "Memory", "m"},
       {"/compare", :compare, "Compare", "Compare processes and memory of up to three nodes",
        "k"},
       {"/kubernetes", :kubernetes, "Kubernetes",
        "Pod, containers, images and events of the connected nodes", "y"},
       {"/logs", :logs, "Logs", "Logs", "o"}
     ]},
    {"Processes",
     [
       {"/", :processes, "Processes", "Processes", "p"},
       {"/gc", :gc, "GC", "Garbage collection", "c"},
       {"/crashes", :crashes, "Crashes", "Crash reports", "x"},
       {"/insights", :insights, "Insights", "Insights: anomalies and groups (Nx)", "i"},
       {"/snapshots", :snapshots, "Snapshots",
        "Stored snapshots of processes that need attention", "d"}
     ]},
    {"Tracing",
     [
       {"/trace", :trace, "Trace", "Tracing", "t"},
       {"/seq", :seq, "Seq", "Seq trace", "q"},
       {"/profile", :profile, "Profile", "Profile", "f"}
     ]}
  ]

  @doc "The tab groups: `[{group, [{path, key, label, title, shortcut}]}]`."
  def tab_groups, do: @groups

  defp multiple_connections?(conn), do: length((conn && conn[:connections]) || []) > 1

  defp visible_groups(compare?) do
    snapshots? = Beamdash.Settings.snapshots_enabled?()

    for {group, tabs} <- @groups,
        do: {group, Enum.filter(tabs, &visible_tab?(elem(&1, 1), snapshots?, compare?))}
  end

  defp visible_tab?(:snapshots, snapshots?, _compare?), do: snapshots?
  defp visible_tab?(:compare, _snapshots?, compare?), do: compare?
  defp visible_tab?(_key, _snapshots?, _compare?), do: true

  attr :active, :any, required: true, doc: "a tab's key, or {:plugin, app, slug}"
  attr :syntax, :atom, required: true

  attr :plugins, :list,
    default: [],
    doc: "the active plugins, `Beamdash.Plugins.active/1`: `[%{app, name, pages}]`"

  attr :compare, :boolean, default: false, doc: "whether the Compare tab is shown"

  @doc """
  The tabs, grouped (node, processes, tracing) with short labels; the full
  name and shortcut show on hover. Tabs that do not fit move into a
  "More" menu (the NavOverflow hook, never the current one). `g` then a
  key opens a tab; `?` lists the keys. Settings is the gear at the end,
  next to the Erlang/Elixir switch.

  With active plugins, a Plugins menu follows the tabs: one group per
  plugin, linking to its pages. It is not a tab, so it is never moved into
  More and has no shortcut.
  """
  def nav(assigns) do
    assigns = assign(assigns, groups: visible_groups(assigns.compare))

    ~H"""
    <nav class="tabs" id="main-nav" phx-hook="NavOverflow" aria-label="Main">
      <%= for {{group, tabs}, i} <- Enum.with_index(@groups) do %>
        <span :if={i > 0} class="tab-sep" aria-hidden="true"></span>
        <.link
          :for={{path, key, label, title, shortcut} <- tabs}
          navigate={path}
          class={["tab", @active == key && "active"]}
          title={"#{title} · #{group} — g #{shortcut}"}
          data-key={shortcut}
          data-overflow-last={key in [:modules, :console] && "true"}
          aria-current={@active == key && "page"}
        >
          {label}
        </.link>
      <% end %>
      <details
        :if={@plugins != []}
        class="tabs-plugins"
        phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["open"])}
      >
        <summary
          class={match?({:plugin, _, _}, @active) && "active"}
          title="Plugins"
          aria-current={match?({:plugin, _, _}, @active) && "page"}
        >
          Plugins ▾
        </summary>
        <div class="tabs-plugins-menu" role="menu">
          <div
            :for={plugin <- @plugins}
            class="plugin-group"
            role="group"
            aria-labelledby={"plugin-group-#{plugin.app}"}
          >
            <span class="plugin-group-name" id={"plugin-group-#{plugin.app}"}>{plugin.name}</span>
            <.link
              :for={page <- plugin.pages}
              navigate={"/plugins/#{plugin.app}/#{page.slug}"}
              class={@active == {:plugin, to_string(plugin.app), page.slug} && "active"}
              role="menuitem"
              aria-current={@active == {:plugin, to_string(plugin.app), page.slug} && "page"}
            >
              {page.label}
            </.link>
          </div>
        </div>
      </details>
      <details
        class="tabs-more"
        hidden
        phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["open"])}
      >
        <summary title="More tabs">More ▾</summary>
        <div id="tabs-more-menu" class="tabs-more-menu" role="menu" phx-update="ignore"></div>
      </details>
    </nav>
    <div class="header-tools">
      <div class="syntax-toggle" role="group" aria-label="Syntax">
        <button
          :for={
            {value, label, title} <- [
              {:erlang, "erl", "Erlang syntax"},
              {:elixir, "ex", "Elixir syntax"}
            ]
          }
          type="button"
          class={@syntax == value && "active"}
          phx-click="set_syntax"
          phx-value-syntax={value}
          title={title}
          aria-pressed={to_string(@syntax == value)}
        >
          {label}
        </button>
      </div>
      <.link
        navigate="/settings"
        class={["tab", "settings-tab", @active == :settings && "active"]}
        title="Settings — g ,"
        data-key=","
        aria-label="Settings"
        aria-current={@active == :settings && "page"}
      >
        ⚙
      </.link>
      <button
        type="button"
        class="help-btn"
        data-shortcuts-open
        title="Keyboard shortcuts — ?"
        aria-label="Keyboard shortcuts"
      >
        ?
      </button>
    </div>
    <dialog id="shortcuts" class="shortcuts" aria-label="Keyboard shortcuts" phx-update="ignore">
      <h3>Keyboard shortcuts</h3>
      <p class="muted small">Press <kbd>g</kbd> then a key. Not while typing in a field.</p>
      <div class="shortcut-groups">
        <dl :for={{group, tabs} <- @groups}>
          <dt>{group}</dt>
          <dd :for={{_path, _key, _label, title, shortcut} <- tabs}>
            <kbd>g</kbd> <kbd>{shortcut}</kbd> {title}
          </dd>
        </dl>
        <dl>
          <dt>Other</dt>
          <dd><kbd>g</kbd> <kbd>,</kbd> Settings</dd>
          <dd><kbd>?</kbd> This list</dd>
        </dl>
      </div>
      <form method="dialog"><button class="secondary">Close</button></form>
    </dialog>
    """
  end
end

defmodule BeamdashWeb.ErrorHTML do
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end
