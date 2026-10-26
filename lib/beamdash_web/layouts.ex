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

  attr :active, :any, required: true, doc: "a tab's key, or {:plugin, app, slug}"
  attr :syntax, :atom, required: true
  attr :conn, :map, default: nil, doc: "from BeamdashWeb.Connection; nil hides the bar"
  attr :ask, :map, default: nil, doc: "from BeamdashWeb.Ask; nil hides the box"
  attr :ask_on, :boolean, default: false, doc: "Jev on and configured"

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
      <.nav active={@active} syntax={@syntax} plugins={(@conn && @conn[:plugins]) || []} />

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
        <div :if={@conn.status != :connected} class="connect-panel">
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
              <select id="kube-cluster" class="wide" name="cluster">
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
                disabled={Map.get(@conn, :kube_pods_listing, false)}
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
                disabled={@conn.kube_binaries == []}
              >
                Connect
              </button>
            </form>
            <p :if={@conn[:kube_binaries] == []} class="conn-hint muted small">
              No binaries found under /app/bin in this pod{if @conn[:kube_container],
                do: " (container #{@conn.kube_container})"}.
            </p>
          </div>
        </div>

        <div :if={@conn.status == :connected} class="connected">
          <span class="dot" aria-hidden="true"></span>
          <strong>{@conn.node}</strong>
          <button phx-click="disconnect" class="secondary">Disconnect</button>
        </div>
      </div>
    </header>
    <p :if={@conn && @conn.error} class="error conn-error" role="alert">{@conn.error}</p>
    <div :if={(@ask && @ask_on) || (@conn && @conn.status == :connected)} class="subbar">
      <div :if={@ask && @ask_on} class="ask">
        <form id="ask-form" phx-submit="ask" role="search">
          <input
            type="search"
            name="ask_q"
            value={@ask.query}
            placeholder="Ask beamdash… e.g. who is leaking binaries?"
            autocomplete="off"
            aria-label="Ask beamdash"
            title="Jev (TypeSafe) picks the view that answers your question; only the question is sent."
            disabled={@ask.busy != nil}
          />
          <button type="submit" class="small-btn" disabled={@ask.busy != nil}>
            {if @ask.busy, do: "Asking…", else: "Ask"}
          </button>
        </form>
        <div :if={@ask.options != [] or @ask.error} class="ask-results" role="status">
          <span :if={@ask.error} class="error small">{@ask.error}</span>
          <span :if={@ask.options != []} class="muted small">Jev suggests:</span>
          <.link :for={o <- @ask.options} navigate={o.path} class="ask-option">
            {o.label} <span class="muted">{round(o.probability * 100)}%</span>
          </.link>
          <button type="button" class="secondary small-btn" phx-click="ask_close" aria-label="Close">
            ×
          </button>
        </div>
      </div>
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
    """
  end

  # The tabs in three groups: the node, its processes, tracing. Each: path,
  # active key, short label, full name, shortcut key (g then the key).
  @groups [
    {"Node",
     [
       {"/system", :system, "System", "System", "s"},
       {"/nodes", :nodes, "Nodes", "Nodes", "n"},
       {"/load", :load, "Load", "Load Charts", "l"},
       {"/apps", :apps, "Apps", "Applications", "a"},
       {"/memory", :memory, "Memory", "Memory", "m"},
       {"/logs", :logs, "Logs", "Logs", "o"}
     ]},
    {"Processes",
     [
       {"/", :processes, "Processes", "Processes", "p"},
       {"/gc", :gc, "GC", "Garbage collection", "c"},
       {"/crashes", :crashes, "Crashes", "Crash reports", "x"}
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

  attr :active, :any, required: true, doc: "a tab's key, or {:plugin, app, slug}"
  attr :syntax, :atom, required: true

  attr :plugins, :list,
    default: [],
    doc: "the active plugins, `Beamdash.Plugins.active/1`: `[%{app, name, pages}]`"

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
    assigns = assign(assigns, groups: @groups)

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
      <details class="tabs-more" hidden>
        <summary title="More tabs">More ▾</summary>
        <div class="tabs-more-menu" role="menu"></div>
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
    <dialog id="shortcuts" class="shortcuts" aria-label="Keyboard shortcuts">
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
