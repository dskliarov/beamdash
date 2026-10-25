defmodule Beamdash.Plugin.Page do
  @moduledoc """
  A plugin page: a LiveView that beamdash embeds under the Plugins menu.

      defmodule MyPlugin.OverviewLive do
        use Beamdash.Plugin.Page

        @impl true
        def plugin_mount(_params, _session, socket) do
          {:ok, load(socket)}
        end

        @impl true
        def connection_changed(_event, socket), do: {:noreply, load(socket)}

        @impl true
        def plugin_info(:refresh, socket), do: {:noreply, load(socket)}

        @impl true
        def handle_event("reload", _params, socket), do: {:noreply, load(socket)}

        @impl true
        def render(assigns) do
          ~H\"\"\"
          <p class="my_plugin-status">{Beamdash.Plugin.Format.term(@status, @syntax)}</p>
          <button phx-click="reload">Reload</button>
          \"\"\"
        end

        defp load(socket) do
          status =
            Beamdash.Plugin.rpc(:my_app, :status, [], 5_000,
              target: socket.assigns.beamdash_target
            )

          assign(socket, status: status)
        end
      end

  `use Beamdash.Plugin.Page` runs `use Phoenix.LiveView`. It defines
  `mount/3` and `handle_info/2` for you. Don't define them yourself: a page
  that does gets a compile error. Use the callbacks below instead.

  ## Assigns

    * `@plugin`: the plugin's declaration (see `Beamdash.Plugin`) plus its
      app: `%{app: atom, name: string, pages: [%{slug, label, module}]}`.
    * `@node`: the attached node, or `nil` when none is attached.
    * `@syntax`: `:erlang` or `:elixir`, the syntax the user picked. Pass it
      to `Beamdash.Plugin.Format`.
    * `@beamdash_target`: the `Beamdash.Target` server. Pass it to
      `Beamdash.Plugin.rpc/5` as `target:`.

  ## Callbacks

  All of them are optional:

    * `c:plugin_mount/3` runs at the end of `mount/3`, after the assigns
      above are set. It defaults to `{:ok, socket}`.
    * `c:connection_changed/2` runs when a node is attached or detached,
      after `@node` is updated. The event is `{:connected, node}` or
      `{:disconnected, reason}`. It defaults to `{:noreply, socket}`, which
      re-renders the page with the new `@node`.
    * `c:plugin_info/2` gets every other message the page receives, such as
      your own `Process.send_after/3` timers. It defaults to
      `{:noreply, socket}`.

  `handle_event/3`, `render/1` and the other LiveView callbacks are the
  page's own, as in any LiveView.

  Mark every callback you define, these and LiveView's, with `@impl true`.
  The generated `mount/3` and `handle_info/2` carry `@impl`, so Elixir
  warns about callbacks without it.

  ## Session

  beamdash mounts the page with `"plugin_app"` (the plugin's app),
  `"plugin_module"` (its entry module) and `"syntax"`. Tests can also pass
  `"target"`, a `Beamdash.Target` server to use instead of the default.
  """

  alias Beamdash.Target
  alias Phoenix.LiveView.Socket

  @doc """
  Runs at the end of `mount/3`, after `@plugin`, `@node`, `@syntax` and
  `@beamdash_target` are assigned. Returns what `mount/3` returns.
  """
  @callback plugin_mount(params :: map() | :not_mounted_at_router, session :: map(), Socket.t()) ::
              {:ok, Socket.t()} | {:ok, Socket.t(), keyword()}

  @doc """
  Handles every message except beamdash's connection events. Returns what
  `handle_info/2` returns.
  """
  @callback plugin_info(msg :: term(), Socket.t()) :: {:noreply, Socket.t()}

  @doc """
  Runs when a node is attached (`{:connected, node}`) or detached
  (`{:disconnected, reason}`), after `@node` is updated.
  """
  @callback connection_changed(event :: term(), Socket.t()) :: {:noreply, Socket.t()}

  @optional_callbacks plugin_mount: 3, plugin_info: 2, connection_changed: 2

  @doc """
  Makes the calling module a plugin page. It is a LiveView, with `mount/3`
  and `handle_info/2` defined for it. See the module doc.
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour Beamdash.Plugin.Page
      # before Phoenix's own hooks, so Phoenix.Component's still runs last
      @before_compile Beamdash.Plugin.Page
      use Phoenix.LiveView
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    for {fun, arity, instead} <- [
          {:mount, 3, "plugin_mount/3"},
          {:handle_info, 2, "plugin_info/2"}
        ],
        Module.defines?(env.module, {fun, arity}) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description:
          "#{inspect(env.module)} uses Beamdash.Plugin.Page, which defines #{fun}/#{arity}. " <>
            "Define #{instead} instead"
    end

    plugin_mount? = Module.defines?(env.module, {:plugin_mount, 3})
    plugin_info? = Module.defines?(env.module, {:plugin_info, 2})
    connection_changed? = Module.defines?(env.module, {:connection_changed, 2})

    mounted =
      if plugin_mount?,
        do: quote(do: plugin_mount(params, session, socket)),
        else: quote(do: {:ok, socket})

    connection =
      if connection_changed?,
        do: quote(do: connection_changed(event, socket)),
        else: quote(do: {:noreply, socket})

    info =
      if plugin_info?,
        do: quote(do: plugin_info(msg, socket)),
        else: quote(do: {:noreply, socket})

    quote generated: true do
      @impl Phoenix.LiveView
      def mount(params, session, socket) do
        socket = Beamdash.Plugin.Page.__mount__(session, socket)
        unquote(mounted)
      end

      @impl Phoenix.LiveView
      def handle_info({:beamdash_target, event}, socket) do
        _ = event
        socket = Beamdash.Plugin.Page.__update_node__(socket)
        unquote(connection)
      end

      def handle_info(msg, socket) do
        _ = msg
        unquote(info)
      end
    end
  end

  @doc false
  def __mount__(session, socket) do
    target = session["target"] || Target
    if Phoenix.LiveView.connected?(socket), do: :ok = Target.subscribe(target)

    socket
    |> Phoenix.Component.assign(
      plugin: plugin(session["plugin_app"], session["plugin_module"]),
      syntax: session["syntax"] || :erlang,
      beamdash_target: target
    )
    |> __update_node__()
  end

  @doc false
  def __update_node__(socket) do
    node = Beamdash.Plugin.__current_node__(socket.assigns.beamdash_target)
    Phoenix.Component.assign(socket, node: node)
  end

  # The entry module's declaration plus the app. Without a usable entry
  # module the page still mounts, with no name and no pages.
  defp plugin(app, module) do
    declaration =
      if is_atom(module) and module != nil and Code.ensure_loaded?(module) and
           function_exported?(module, :__beamdash_plugin__, 0),
         do: module.__beamdash_plugin__(),
         else: %{name: nil, pages: []}

    Map.put(declaration, :app, app)
  end
end
