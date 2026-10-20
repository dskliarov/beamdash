defmodule ExberlyWeb.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>exberly</title>
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

  attr :active, :atom, required: true
  attr :syntax, :atom, required: true
  attr :conn, :map, default: nil, doc: "from ExberlyWeb.Connection; nil hides the bar"
  attr :ask, :map, default: nil, doc: "from ExberlyWeb.Ask; nil hides the box"
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
      <h1>exberly</h1>
      <.nav active={@active} syntax={@syntax} />

      <div :if={@conn} class="conn-line">
        <form
          :if={@conn && @conn.status != :connected}
          id="connect-form"
          phx-submit="connect"
          class="connect"
        >
          <input
            name="node"
            value={@conn.node_input}
            placeholder="node@host"
            required
            autocomplete="off"
            aria-label="Node"
          />
          <input
            name="cookie"
            type="password"
            value={Map.get(@conn, :cookie_input, "")}
            placeholder="cookie (optional)"
            autocomplete="off"
            aria-label="Cookie"
          />
          <button type="submit" phx-disable-with="Connecting…">Connect</button>
        </form>

        <div :if={@conn && @conn.status == :connected} class="connected">
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
            placeholder="Ask exberly… e.g. who is leaking binaries?"
            autocomplete="off"
            aria-label="Ask exberly"
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
          <span>{Exberly.Format.number(@conn.info.process_count)} processes</span>
          <span>{Exberly.Format.bytes(@conn.info.memory_total)} memory</span>
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
       {"/load", :load, "Load", "Load Charts", "l"},
       {"/apps", :apps, "Apps", "Applications", "a"},
       {"/memory", :memory, "Memory", "Memory", "m"}
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

  attr :active, :atom, required: true
  attr :syntax, :atom, required: true

  @doc """
  The tabs, grouped (node, processes, tracing) with short labels; the full
  name and shortcut show on hover. Tabs that do not fit move into a
  "More" menu (the NavOverflow hook, never the current one). `g` then a
  key opens a tab; `?` lists the keys. Settings is the gear at the end,
  next to the Erlang/Elixir switch.
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

defmodule ExberlyWeb.ErrorHTML do
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end
