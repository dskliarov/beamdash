defmodule Beamdash.Plugin do
  @moduledoc """
  The public API for beamdash plugins. A plugin adds pages to beamdash
  for one application (riak_core, say). It shows them in the Plugins menu
  while that application runs on the attached node.

  ## A plugin project

  A plugin is an ordinary Mix project:

      mix.exs                    app: :my_plugin, deps (see below)
      lib/my_plugin.ex           the entry module: use Beamdash.Plugin
      lib/my_plugin/*.ex         the pages: use Beamdash.Plugin.Page
      priv/static/plugin.css     optional

  The entry module declares the plugin's name and pages:

      defmodule MyPlugin do
        use Beamdash.Plugin,
          name: "My app",
          pages: [
            {"overview", "Overview", MyPlugin.OverviewLive},
            {"workers", "Workers", MyPlugin.WorkersLive}
          ]
      end

  Each page is `{slug, label, module}`:

    * `slug` is the page's URL segment. It must match
      `\\A[a-z][a-z0-9_-]{0,31}\\z`, and it must be unique within the plugin.
    * `label` is a string. It is shown in the Plugins menu.
    * `module` is the page's LiveView, which uses `Beamdash.Plugin.Page`.

  The applications the plugin supports, with their versions, are not
  options here. List them in `mix.exs` as `runtime: false` deps. beamdash
  reads the deps as data and never runs `mix.exs`:

      defp deps do
        [
          {:my_app, "~> 1.2", runtime: false},
          {:phoenix_live_view, "~> 1.0"},
          {:beamdash, path: "../beamdash", only: [:dev, :test], runtime: false}
        ]
      end

  The plugin is active while one of these applications runs on the attached
  node at a version that matches the requirement.

  ## Rules

    * Every module must be the entry module or nested under it
      (`MyPlugin.*`).
    * A plugin can only use libraries beamdash ships: Elixir, Phoenix,
      Phoenix LiveView, Jason and so on.
    * Code on the attached node can only be called with `rpc/5`, for example
      `Beamdash.Plugin.rpc(:my_app_server, :status, [])`. A direct call like
      `:my_app_server.status()` would run inside beamdash, where that module
      doesn't exist, and the install refuses it.
    * CSS goes in `priv/static/plugin.css`. It is loaded on the plugin's
      pages only. Prefix the class names with the plugin's app name.
  """

  alias Beamdash.{Apps, Target}

  @options [:name, :pages]

  @doc """
  Declares the calling module as a plugin's entry module.

  Options, both required:

    * `:name`: the plugin's display name, a string.
    * `:pages`: a list of `{slug, label, module}` tuples.

  Defines `__beamdash_plugin__/0`, which returns
  `%{name: name, pages: [%{slug: slug, label: label, module: module}]}`.

  The options are checked at compile time. They must be literals, apart from
  aliases for the page modules. The page modules don't need to be compiled
  yet. Supported applications go in `mix.exs` as `runtime: false` deps, not
  here.

      use Beamdash.Plugin,
        name: "riak_core",
        pages: [{"ring", "Ring", RiakCorePlugin.RingLive}]
  """
  defmacro __using__(opts) do
    declaration = declaration!(opts, __CALLER__)

    quote do
      @doc false
      def __beamdash_plugin__, do: unquote(Macro.escape(declaration))
    end
  end

  @doc """
  Calls `mod.fun(args)` on the attached node.

  Returns `{:ok, result}`, or `{:error, {kind, reason}}` when the call
  raises, exits or times out (`timeout` is in milliseconds). Returns
  `{:error, :not_connected}` when no node is attached, or when the target
  server isn't running or doesn't answer (it can be busy connecting).
  `opts` takes `target:`, the `Beamdash.Target` server to use. Pages pass
  `@beamdash_target` there.
  """
  @spec rpc(module(), atom(), list(), timeout(), keyword()) ::
          {:ok, term()} | {:error, :not_connected | term()}
  def rpc(mod, fun, args, timeout \\ 5_000, opts \\ [])
      when is_atom(mod) and is_atom(fun) and is_list(args) and is_list(opts) do
    case __current_node__(Keyword.get(opts, :target, Target)) do
      nil -> {:error, :not_connected}
      node -> Target.rpc(node, mod, fun, args, timeout)
    end
  end

  @doc "Whether application `app` is running on the attached node."
  @spec app_running?(atom(), GenServer.server()) :: boolean()
  def app_running?(app, target \\ Target), do: app_version(app, target) != :not_running

  @doc """
  The version of application `app` running on the attached node, such as
  `{:ok, "0.11.1"}`. Returns `:not_running` when it isn't running there, or
  when no node is attached. Library applications count, as they do for the
  Plugins menu.
  """
  @spec app_version(atom(), GenServer.server()) :: {:ok, String.t()} | :not_running
  def app_version(app, target \\ Target) when is_atom(app) do
    with node when node != nil <- __current_node__(target),
         {:ok, running} <- Apps.running(node),
         {_, vsn} <- List.keyfind(running, app, 0) do
      {:ok, vsn}
    else
      _ -> :not_running
    end
  end

  # The attached node, or nil: also when `target` isn't running (:noproc)
  # or doesn't answer in time (busy in a long kubectl connect).
  @doc false
  @spec __current_node__(GenServer.server()) :: node() | nil
  def __current_node__(target) do
    case Target.status(target) do
      %{status: :connected, node: node} -> node
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  @doc """
  The path of beamdash's details page for `pid`, a process on the attached
  node, to link to it: `<.link navigate={Beamdash.Plugin.process_path(pid)}>`.
  """
  @spec process_path(pid()) :: String.t()
  def process_path(pid) when is_pid(pid),
    do: "/?pid=" <> URI.encode_www_form(Beamdash.Format.pid(pid, :erlang))

  @doc """
  A link that moves beamdash's connection to `node`, a node the attached
  node is connected to, as clicking it on the Nodes tab does. With
  `return_to` (a beamdash path, such as the page's own
  `"/plugins/my_plugin/overview"`), beamdash comes back there once
  connected; a switch that fails stays on the Nodes tab, which says why.
  `<.link navigate={Beamdash.Plugin.switch_path(node, path)}>`.
  """
  @spec switch_path(node(), String.t() | nil) :: String.t()
  def switch_path(node, return_to \\ nil) when is_atom(node) do
    query = [switch: Atom.to_string(node)] ++ if(return_to, do: [return: return_to], else: [])
    "/nodes?" <> URI.encode_query(query)
  end

  @doc "beamdash's own version, such as `\"0.1.0\"`."
  @spec version() :: String.t()
  def version, do: to_string(Application.spec(:beamdash, :vsn))

  @doc false
  # Whether `slug` is a valid page slug. Also used by the install's check of
  # a compiled `__beamdash_plugin__/0`.
  @spec __valid_slug__?(term()) :: boolean()
  def __valid_slug__?(slug), do: is_binary(slug) and Regex.match?(slug_regex(), slug)

  # Not a module attribute: a compiled regex can't be escaped into code on
  # OTP 28 with Elixir < 1.19.
  defp slug_regex, do: ~r/\A[a-z][a-z0-9_-]{0,31}\z/

  ## Option checks (compile time)

  defp declaration!(opts, env) do
    fail = fn message ->
      raise ArgumentError, "use Beamdash.Plugin in #{inspect(env.module)}: #{message}"
    end

    unless is_list(opts) and Enum.all?(opts, &match?({key, _} when is_atom(key), &1)) do
      fail.("expected a keyword list with :name and :pages, got: #{Macro.to_string(opts)}")
    end

    keys = Keyword.keys(opts)

    case keys -- @options do
      [] ->
        :ok

      [key | _] when key in [:apps, :beamdash, :versions] ->
        fail.(
          "unknown option #{inspect(key)}. The supported options are :name and :pages. " <>
            "Supported applications, and the beamdash version, go in mix.exs as " <>
            "`runtime: false` deps, for example {:riak_core, \"~> 0.10\", runtime: false}"
        )

      [key | _] ->
        fail.("unknown option #{inspect(key)}. The supported options are :name and :pages")
    end

    case keys -- Enum.uniq(keys) do
      [] -> :ok
      [key | _] -> fail.("option #{inspect(key)} is given more than once")
    end

    for key <- @options, not Keyword.has_key?(opts, key), do: fail.("missing #{inspect(key)}")

    name = Keyword.fetch!(opts, :name)

    unless is_binary(name) and name != "" do
      fail.(":name must be a non-empty string, got: #{Macro.to_string(name)}")
    end

    %{name: name, pages: pages!(Keyword.fetch!(opts, :pages), env, fail)}
  end

  defp pages!(pages, env, fail) do
    unless is_list(pages) and pages != [] do
      fail.(
        ":pages must be a non-empty list of {slug, label, module}, got: #{Macro.to_string(pages)}"
      )
    end

    pages = Enum.map(pages, &page!(&1, env, fail))

    pages
    |> Enum.map(& &1.slug)
    |> Enum.reduce(MapSet.new(), fn slug, seen ->
      if MapSet.member?(seen, slug), do: fail.("duplicate slug #{inspect(slug)} in :pages")
      MapSet.put(seen, slug)
    end)

    pages
  end

  defp page!({:{}, _, [slug, label, module]} = page, env, fail) do
    unless __valid_slug__?(slug) do
      fail.(
        "invalid slug #{Macro.to_string(slug)} in :pages. " <>
          "A slug is a string matching #{inspect(Regex.source(slug_regex()))}"
      )
    end

    unless is_binary(label) do
      fail.("the label of page #{inspect(slug)} must be a string, got: #{Macro.to_string(label)}")
    end

    case Macro.expand(module, env) do
      mod when is_atom(mod) and mod not in [nil, true, false] ->
        %{slug: slug, label: label, module: mod}

      _ ->
        fail.(
          "the module of page #{inspect(slug)} must be a module name (an alias or an atom), " <>
            "got: #{Macro.to_string(module)} in #{Macro.to_string(page)}"
        )
    end
  end

  defp page!(other, _env, fail) do
    fail.(":pages must be a list of {slug, label, module} tuples, got: #{Macro.to_string(other)}")
  end
end
