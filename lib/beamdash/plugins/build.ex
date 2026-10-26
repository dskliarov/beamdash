defmodule Beamdash.Plugins.Build do
  @moduledoc """
  Turns a fetched plugin source into loaded code, in four steps that each
  stand alone:

    * `read_project/1` reads the plugin's `mix.exs` as data: it is parsed
      with `Code.string_to_quoted/2` and never evaluated. The parser has a
      `:static_atoms_encoder`, so reading creates no atoms; an atom is made
      only after its name matches `\\A[a-z][a-z0-9_]{0,63}\\z`.
    * `scan/2` parses `lib/**/*.ex` (again, without running anything) and
      refuses module names that beamdash, OTP, a dependency or another plugin
      already has, before anything is compiled.
    * `compile/2` compiles into a private ebin in the running VM.
    * `check/3` checks the result: the entry module, the pages, and that the
      beams only call modules beamdash has.

  `safe_rm_rf/1` is the only way plugin folders are deleted. It refuses
  anything that is not strictly inside `plugins_dir/0`.
  """

  alias Beamdash.Plugin

  @name_re ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @segment_re ~r/\A[A-Z][A-Za-z0-9_]{0,254}\z/
  @max_bytes 1_000_000
  @max_modules 500
  @max_deps 100
  @max_message 800
  @deps_msg "deps must be a literal list in mix.exs"
  @no_support_msg "declare the application it supports as a runtime: false dependency in mix.exs"

  @type requirement :: String.t() | nil

  ## Directories

  @doc "The directory plugins are installed in."
  @spec plugins_dir() :: Path.t()
  def plugins_dir, do: Application.get_env(:beamdash, :plugins_dir) || default_plugins_dir()

  @doc false
  # Where plugins go when `:plugins_dir` isn't set.
  @spec default_plugins_dir() :: Path.t()
  def default_plugins_dir, do: Path.join(:filename.basedir(:user_config, "beamdash"), "plugins")

  @doc "The folder of plugin `app` inside `plugins_dir/0`."
  @spec install_dir(atom() | String.t()) :: Path.t()
  def install_dir(app), do: Path.join(plugins_dir(), to_string(app))

  @doc """
  Deletes `path` and everything in it, but only when it is strictly inside
  `plugins_dir/0`. Returns `{:error, message}` and deletes nothing when it is
  the plugins dir itself, is outside it, or is or sits under a symbolic link.
  Both paths are compared after their symbolic links are resolved, so
  `/tmp` against `/private/tmp` doesn't matter.
  """
  @spec safe_rm_rf(Path.t()) :: :ok | {:error, String.t()}
  def safe_rm_rf(path) when is_binary(path) do
    case guard(path) do
      {:ok, real} ->
        case File.rm_rf(real) do
          {:ok, _} ->
            :ok

          {:error, reason, file} ->
            {:error, "could not delete #{file}: #{:file.format_error(reason)}"}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  True when `path` is `plugins_dir/0` or inside it, after both are expanded
  and their symbolic links resolved. A path plugin's folder must not be:
  beamdash deletes what it keeps there.
  """
  @spec in_plugins_dir?(Path.t()) :: boolean()
  def in_plugins_dir?(path) do
    with {:ok, real_root} <- resolve(plugins_dir()),
         {:ok, real} <- resolve(path) do
      root_parts = Path.split(real_root)
      Enum.take(Path.split(real), length(root_parts)) == root_parts
    else
      _ -> false
    end
  end

  defp guard(path) do
    root = Path.expand(plugins_dir())
    target = Path.expand(path)
    refuse = {:error, "refusing to delete #{path}: it is not inside the plugins folder #{root}"}

    with {:ok, real_root} <- resolve(root),
         {:ok, real_parent} <- resolve(Path.dirname(target)) do
      real = Path.join(real_parent, Path.basename(target))

      with {:ok, rel} <- strictly_inside(real_root, real, refuse),
           :ok <- no_symlinks(real_root, rel, path),
           :ok <- lexical_no_symlinks(root, target, path) do
        {:ok, real}
      end
    end
  end

  # The components of `path` below `root`, if there are any.
  defp strictly_inside(root, path, refuse) do
    root_parts = Path.split(root)
    parts = Path.split(path)

    if length(parts) > length(root_parts) and Enum.take(parts, length(root_parts)) == root_parts,
      do: {:ok, Enum.drop(parts, length(root_parts))},
      else: refuse
  end

  defp lexical_no_symlinks(root, target, original) do
    case strictly_inside(root, target, :outside) do
      {:ok, rel} -> no_symlinks(root, rel, original)
      :outside -> :ok
    end
  end

  # No component of root/rel/... is a symlink (the last one included).
  defp no_symlinks(root, rel, original) do
    rel
    |> Enum.scan(root, &Path.join(&2, &1))
    |> Enum.find(&symlink?/1)
    |> case do
      nil -> :ok
      link -> {:error, "refusing to delete #{original}: #{link} is a symbolic link"}
    end
  end

  defp symlink?(path) do
    match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))
  end

  # The path with every symbolic link in it followed, component by component.
  defp resolve(path), do: resolve(path, 0)

  defp resolve(_path, depth) when depth > 40, do: {:error, "too many levels of symbolic links"}

  defp resolve(path, depth) do
    [root | parts] = path |> Path.expand() |> Path.split()
    follow(root, parts, depth)
  end

  defp follow(acc, [], _depth), do: {:ok, acc}

  defp follow(acc, [part | rest], depth) do
    candidate = Path.join(acc, part)

    case File.read_link(candidate) do
      {:ok, link} ->
        with {:ok, resolved} <- resolve(Path.expand(link, acc), depth + 1),
             do: follow(resolved, rest, depth + 1)

      {:error, _} ->
        follow(candidate, rest, depth)
    end
  end

  ## Loading

  @doc "Purges and deletes each module, twice, so old code goes too."
  @spec unload([module()]) :: :ok
  def unload(modules) do
    for module <- modules, _ <- 1..2 do
      :code.purge(module)
      :code.delete(module)
    end

    :ok
  end

  ## mix.exs

  @doc """
  Reads the plugin's `mix.exs` as data and splits its deps. See the moduledoc
  of `Beamdash.Plugin` for the rules.
  """
  @spec read_project(Path.t()) ::
          {:ok,
           %{
             app: atom(),
             supports: [{atom(), requirement()}],
             beamdash_req: requirement(),
             shipped: [{atom(), requirement()}]
           }}
          | {:error, String.t()}
  def read_project(src) do
    with {:ok, ast} <- parse_file(Path.join(src, "mix.exs"), "mix.exs"),
         {:ok, stmts} <- module_body(ast),
         {:ok, project} <- project_list(stmts),
         {:ok, app} <- app_name(project),
         {:ok, deps} <- deps_list(project, stmts),
         {:ok, split} <- split_deps(deps) do
      {:ok, Map.put(split, :app, app)}
    end
  end

  # A symbolic link is refused, not followed, as in lib/.
  defp parse_file(path, label) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_bytes ->
        with {:ok, text} <- File.read(path), do: quote_text(text, label)

      {:ok, %File.Stat{type: :regular}} ->
        {:error, "#{label} is too big"}

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, "#{label} is a symbolic link; beamdash doesn't follow it"}

      _ ->
        {:error, "#{label} not found"}
    end
  end

  # Atoms come back as %{atom: string}: a map never appears in a literal AST,
  # so they stay distinct from strings and none is created.
  defp quote_text(text, label) do
    encoder = fn token, _meta -> {:ok, %{atom: token}} end

    case Code.string_to_quoted(text, static_atoms_encoder: encoder, emit_warnings: false) do
      {:ok, ast} ->
        {:ok, ast}

      {:error, {meta, message, token}} ->
        {:error, "#{label}#{syntax_error(meta, message, token)}"}
    end
  rescue
    _ -> {:error, "#{label} could not be read"}
  end

  defp syntax_error(meta, message, token) do
    line = if is_list(meta), do: Keyword.get(meta, :line), else: meta
    message = if is_tuple(message), do: Enum.join(Tuple.to_list(message)), else: message
    ":#{line}: #{message}#{if is_binary(token), do: token, else: ""}"
  end

  defp module_body({:__block__, _, [single]}), do: module_body(single)

  defp module_body({%{atom: "defmodule"}, _, [_name, kw]}) when is_list(kw) do
    case do_body(kw) do
      {:ok, body} -> {:ok, statements(body)}
      :error -> {:error, "mix.exs has no module body"}
    end
  end

  defp module_body(_), do: {:error, "mix.exs must define one module with def project"}

  defp statements({:__block__, _, stmts}) when is_list(stmts), do: stmts
  defp statements(stmt), do: [stmt]

  defp do_body(kw) do
    Enum.find_value(kw, :error, fn
      {:do, body} -> {:ok, body}
      {%{atom: "do"}, body} -> {:ok, body}
      _ -> nil
    end)
  end

  # The literal keyword list returned by `def project`.
  defp project_list(stmts) do
    with {:ok, body} <- find_def(stmts, "project"),
         {:ok, list} <- literal_pairs(body) do
      {:ok, list}
    else
      :none -> {:error, "mix.exs has no def project"}
      _ -> {:error, "project in mix.exs must return a literal keyword list"}
    end
  end

  defp find_def(stmts, name) do
    stmts
    |> Enum.find_value(:none, fn
      {%{atom: kind}, _, [{%{atom: ^name}, _, args}, kw]}
      when kind in ["def", "defp"] and args in [nil, []] and is_list(kw) ->
        do_body(kw)

      _ ->
        nil
    end)
    |> case do
      {:ok, body} -> {:ok, unwrap(body)}
      other -> other
    end
  end

  defp unwrap({:__block__, _, [single]}), do: unwrap(single)
  defp unwrap(other), do: other

  # [{"key", ast}] for a keyword list literal, else :error.
  defp literal_pairs(list) when is_list(list) do
    if Enum.all?(list, &match?({%{atom: key}, _} when is_binary(key), &1)),
      do: {:ok, for({%{atom: key}, value} <- list, do: {key, value})},
      else: :error
  end

  defp literal_pairs(_), do: :error

  defp app_name(project) do
    case List.keyfind(project, "app", 0) do
      {_, %{atom: name}} ->
        if Regex.match?(@name_re, name),
          do: {:ok, String.to_atom(name)},
          else:
            {:error,
             "app: #{inspect(String.slice(name, 0, 40))} in mix.exs is not a valid plugin name (lowercase letters, digits and _)"}

      _ ->
        {:error, "mix.exs needs a literal app: :my_plugin in project/0 (it is never run)"}
    end
  end

  defp deps_list(project, stmts) do
    case List.keyfind(project, "deps", 0) do
      nil -> {:ok, []}
      {_, list} when is_list(list) -> {:ok, list}
      {_, {%{atom: name}, _, args}} when args in [nil, []] -> local_deps(stmts, name)
      _ -> {:error, @deps_msg}
    end
  end

  defp local_deps(stmts, name) do
    case find_def(stmts, name) do
      {:ok, list} when is_list(list) -> {:ok, list}
      _ -> {:error, @deps_msg}
    end
  end

  defp split_deps(deps) when length(deps) > @max_deps, do: {:error, "too many deps in mix.exs"}

  defp split_deps(deps) do
    acc = %{supports: [], shipped: [], beamdash_req: nil}

    result =
      Enum.reduce_while(deps, {:ok, acc}, fn dep, {:ok, acc} ->
        with {:ok, name, req, opts} <- read_dep(dep),
             {:ok, acc} <- classify(name, req, opts, acc) do
          {:cont, {:ok, acc}}
        else
          {:error, _} = error -> {:halt, error}
        end
      end)

    with {:ok, acc} <- result do
      if acc.supports == [],
        do: {:error, @no_support_msg},
        else:
          {:ok, %{acc | supports: Enum.reverse(acc.supports), shipped: Enum.reverse(acc.shipped)}}
    end
  end

  # {:ok, name_string, requirement | nil, opts} for {name, req}, {name, opts}
  # and {name, req, opts}, where every value is a literal.
  defp read_dep({%{atom: name}, req}) when is_binary(name) and is_binary(req),
    do: dep_parts(name, req, [])

  defp read_dep({%{atom: name}, opts}) when is_binary(name) and is_list(opts),
    do: dep_parts(name, nil, opts)

  defp read_dep({:{}, _, [%{atom: name}, req, opts]})
       when is_binary(name) and is_binary(req) and is_list(opts),
       do: dep_parts(name, req, opts)

  defp read_dep({%{atom: name}, _}) when is_binary(name), do: not_literal(name)
  defp read_dep({:{}, _, [%{atom: name} | _]}) when is_binary(name), do: not_literal(name)

  defp read_dep(_),
    do: {:error, "every dep in mix.exs must be a literal tuple like {:name, \"~> 1.0\"}"}

  defp not_literal(name) do
    {:error,
     "dep #{name} in mix.exs must be written with literal values (no module attributes or calls)"}
  end

  defp dep_parts(name, req, opts) do
    case literal_opts(opts) do
      {:ok, opts} ->
        if Regex.match?(@name_re, name),
          do: {:ok, name, req, opts},
          else: {:error, "invalid dep name #{inspect(String.slice(name, 0, 40))} in mix.exs"}

      :error ->
        not_literal(name)
    end
  end

  # [{"key", literal}] with atoms as {:a, string}.
  defp literal_opts(opts) do
    Enum.reduce_while(opts, {:ok, []}, fn
      {%{atom: key}, value}, {:ok, acc} when is_binary(key) ->
        case literal(value) do
          {:ok, term} -> {:cont, {:ok, [{key, term} | acc]}}
          :error -> {:halt, :error}
        end

      _, _ ->
        {:halt, :error}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp literal(%{atom: name}) when is_binary(name), do: {:ok, {:a, name}}
  defp literal(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: {:ok, v}
  defp literal(list) when is_list(list), do: literal_all(list)

  defp literal({a, b}) do
    with {:ok, a} <- literal(a), {:ok, b} <- literal(b), do: {:ok, {a, b}}
  end

  defp literal({:{}, _, items}) when is_list(items), do: literal_all(items)
  defp literal(_), do: :error

  defp literal_all(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case literal(item) do
        {:ok, term} -> {:cont, {:ok, [term | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp classify("beamdash", req, _opts, acc) do
    with {:ok, _} <- requirement(req, "beamdash") do
      if req == nil or Version.match?(Plugin.version(), req, allow_pre: true),
        do: {:ok, %{acc | beamdash_req: req}},
        else: {:error, "needs beamdash #{req}, this is #{Plugin.version()}"}
    end
  end

  defp classify(name, req, opts, acc) do
    cond do
      List.keyfind(opts, "runtime", 0) == {"runtime", false} ->
        with {:ok, _} <- requirement(req, name) do
          {:ok, %{acc | supports: [{String.to_atom(name), req} | acc.supports]}}
        end

      vsn = loaded_version(name) ->
        shipped(name, req, vsn, acc)

      true ->
        {:error, "needs #{name}, which beamdash doesn't ship"}
    end
  end

  # An application beamdash has loaded has its atom already.
  defp loaded_version(name) do
    case Application.spec(String.to_existing_atom(name), :vsn) do
      nil -> nil
      vsn -> List.to_string(vsn)
    end
  rescue
    ArgumentError -> nil
  end

  defp shipped(name, req, vsn, acc) do
    with {:ok, _} <- requirement(req, name) do
      if req == nil or version_match?(vsn, req),
        do: {:ok, %{acc | shipped: [{String.to_existing_atom(name), req} | acc.shipped]}},
        else: {:error, "needs #{name} #{req}, but beamdash ships #{vsn}"}
    end
  end

  defp version_match?(vsn, req) do
    case Version.parse(pad_version(vsn)) do
      {:ok, version} -> Version.match?(version, req, allow_pre: true)
      :error -> false
    end
  end

  defp pad_version(vsn) do
    case String.split(vsn, ".") do
      [_] -> vsn <> ".0.0"
      [_, _] -> vsn <> ".0"
      _ -> vsn
    end
  end

  defp requirement(nil, _name), do: {:ok, nil}

  defp requirement(req, name) do
    case Version.parse_requirement(req) do
      {:ok, parsed} ->
        {:ok, parsed}

      :error ->
        {:error,
         "dep #{name} has an invalid version requirement #{inspect(String.slice(req, 0, 40))}"}
    end
  end

  ## Scanning sources

  @not_alias_msg "a module name in lib/ is not a plain alias, which beamdash can't check without compiling it"

  @doc """
  Parses `lib/**/*.ex` without running anything and checks the module names.
  `allow:` lists modules that may already be loaded: those of the same plugin
  when it is rebuilt.

  The names are worked out the way the compiler does: a nested `defmodule`
  joins its parent, a leading `Elixir.` or `__MODULE__` makes it absolute, and
  `defimpl Proto, for: Target` defines `Proto.Target`. Anything that would
  make this guess wrong is refused: a `defmodule`/`defimpl`/`defprotocol` head
  starting with a name set by an earlier `alias` (or `require ..., as:`), and
  `Kernel.defmodule`, `Kernel.SpecialForms.*`, `Module.create` and
  `:elixir_module` calls, as well as `Code.compile_*`, `Code.require_file`
  and `:code.load_binary`, which load code at compile time. `compile/2` also
  refuses any module it didn't predict. `modules` includes the `defimpl`
  modules (`Proto.Target`).

  The scan is best-effort: it recognises the usual forms, not every way of
  reaching these calls (`apply/3`, an imported `create/3`, `Code.eval_*`, a
  module written as an atom). Those that compile a module are caught by
  `compile/3`. Code that a plugin runs at compile time is trusted, as the
  plugin itself is.

  Accepted gap (trust model): modules generated by macros from other
  libraries (`use SomeDep`) or by compile-time code are not seen here. They
  are still caught after compiling, by `compile/2` comparing its output with
  this scan, before anything is loaded.
  """
  @spec scan(Path.t(), keyword()) ::
          {:ok, %{prefix: module(), modules: [module()]}} | {:error, String.t()}
  def scan(src, opts \\ []) do
    allow = Keyword.get(opts, :allow, [])

    with {:ok, found} <- scan_files(src),
         {:ok, prefix_name} <- single_prefix(found.names),
         defined = Enum.map(found.names, &Module.concat/1),
         modules = Enum.uniq(defined ++ impl_modules(found.impls)),
         :ok <- impls_under_prefix(found.impls, prefix_name),
         :ok <- renames_under_prefix(found.renames, prefix_name),
         :ok <- no_clashes(modules, allow),
         prefix = Module.concat([prefix_name]),
         :ok <- namespace_free(prefix, allow),
         :ok <- prefix_defined(defined, prefix) do
      {:ok, %{prefix: prefix, modules: modules}}
    end
  end

  defp scan_files(src) do
    case ex_files(src) do
      [] ->
        {:error, "no .ex files under lib/"}

      files ->
        files
        |> Enum.reduce_while({:ok, %{names: [], impls: [], renames: []}}, fn file, {:ok, acc} ->
          with {:ok, ast} <- parse_file(file, Path.relative_to(file, src)),
               {:ok, found} <- collect(ast) do
            {:cont, {:ok, Map.merge(acc, found, fn _k, a, b -> a ++ b end)}}
          else
            {:error, message} -> {:halt, {:error, "#{Path.relative_to(file, src)}: #{message}"}}
          end
        end)
        |> case do
          {:ok, %{names: names}} when length(names) > @max_modules ->
            {:error, "too many modules (more than #{@max_modules})"}

          {:ok, %{names: []}} ->
            {:error, "no modules are defined in lib/"}

          {:ok, found} ->
            {:ok, %{found | names: Enum.uniq(found.names)}}

          error ->
            error
        end
    end
  end

  # All lib/**/*.ex regular files, sorted. Symbolic links are not followed.
  defp ex_files(src), do: src |> Path.join("lib") |> walk_ex() |> Enum.sort()

  defp walk_ex(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          path = Path.join(dir, entry)

          case File.lstat(path) do
            {:ok, %File.Stat{type: :directory}} ->
              walk_ex(path)

            {:ok, %File.Stat{type: :regular}} ->
              if Path.extname(path) == ".ex", do: [path], else: []

            _ ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  # {:ok, %{names:, impls:, renames:}}: module names as lists of segment
  # strings, `defimpl` pairs {protocol_segments, target_segments}, and the
  # targets of `alias X, as: Y` (segments, or :unknown).
  defp collect(ast) do
    acc =
      walk(ast, nil, %{names: [], impls: [], renames: [], aliases: MapSet.new(), errors: []})

    case acc.errors do
      [] ->
        {:ok,
         %{
           names: Enum.reverse(acc.names),
           impls: Enum.reverse(acc.impls),
           renames: Enum.reverse(acc.renames)
         }}

      errors ->
        {:error, List.last(errors)}
    end
  end

  defp error(acc, message), do: %{acc | errors: [message | acc.errors]}

  defp walk(list, parent, acc) when is_list(list),
    do: Enum.reduce(list, acc, &walk(&1, parent, &2))

  defp walk({%{atom: kind}, _, [head | rest]}, parent, acc)
       when kind in ["defmodule", "defprotocol"] do
    acc = check_head(head, acc)

    case module_name(head, parent) do
      {:ok, full} -> walk(rest, full, %{acc | names: [full | acc.names]})
      {:error, message} -> error(acc, message)
    end
  end

  defp walk({%{atom: "defimpl"}, _, [proto | rest]}, parent, acc) do
    acc = check_head(proto, acc)
    targets = impl_targets(rest, parent)

    acc =
      Enum.reduce(targets, acc, fn
        :parent, acc -> acc
        ast, acc -> check_head(ast, acc)
      end)

    with {:ok, proto_name} <- absolute_name(proto, parent),
         {:ok, target_names} <- resolve_targets(targets, parent) do
      impls = for target <- target_names, do: {proto_name, target}
      body_parent = proto_name ++ hd(target_names)
      walk(rest, body_parent, %{acc | impls: Enum.reverse(impls) ++ acc.impls})
    else
      {:error, message} -> error(acc, message)
    end
  end

  defp walk({%{atom: kind}, _, [target | opts]}, parent, acc) when kind in ["alias", "require"],
    do: add_aliases(kind, target, opts, parent, acc)

  defp walk({{:., _, [mod, fun]}, _, args} = _call, parent, acc) do
    case forbidden_call(mod, fun) do
      nil -> walk(args, parent, walk(mod, parent, acc))
      message -> error(acc, message)
    end
  end

  defp walk({a, b}, parent, acc), do: walk(b, parent, walk(a, parent, acc))

  defp walk({form, _meta, args}, parent, acc) when is_list(args),
    do: walk(args, parent, walk(form, parent, acc))

  defp walk(_other, _parent, acc), do: acc

  # A head whose first segment is an alias set earlier in the file would
  # compile to the alias's target, not to the name scanned here.
  defp check_head({:__aliases__, _, [%{atom: first} | _]}, acc) when first != "Elixir" do
    if MapSet.member?(acc.aliases, first),
      do:
        error(
          acc,
          "#{first} is an alias here, so beamdash can't tell which module this defines; " <>
            "write the full module name"
        ),
      else: acc
  end

  defp check_head(_ast, acc), do: acc

  defp add_aliases(kind, target, opts, parent, acc) do
    as_names =
      for kw <- opts,
          is_list(kw),
          {%{atom: "as"}, {:__aliases__, _, [%{atom: name}]}} <- kw,
          do: name

    names =
      cond do
        as_names != [] -> as_names
        kind == "alias" -> alias_names(target, parent)
        true -> []
      end

    renames =
      if as_names != [] do
        case absolute_name(target, parent) do
          {:ok, segments} -> [segments]
          {:error, _} -> [:unknown]
        end
      else
        []
      end

    %{acc | aliases: Enum.into(names, acc.aliases), renames: renames ++ acc.renames}
  end

  # `alias Other, as: Short` would let a later `defmodule Short.X` define
  # `Other.X`; only names under the plugin's own prefix may be renamed.
  defp renames_under_prefix(renames, prefix) do
    case Enum.find(renames, &(&1 == :unknown or hd(&1) != prefix)) do
      nil ->
        :ok

      :unknown ->
        {:error, "alias ..., as: needs a plain module name under #{prefix}"}

      target ->
        {:error,
         "alias #{Enum.join(target, ".")}, as: ... is not allowed: only modules under #{prefix} may be aliased with as:"}
    end
  end

  # The names `alias X` defines: the last segment of each aliased module.
  # `alias Top` (one segment, as with `alias __MODULE__` in a top-level
  # module) maps a name to itself, so it changes nothing.
  defp alias_names({:__aliases__, _, [%{atom: "Elixir"}, %{atom: _}]}, _parent), do: []
  defp alias_names({:__aliases__, _, [%{atom: _}]}, _parent), do: []

  defp alias_names({:__aliases__, _, parts}, parent) do
    case List.last(parts) do
      %{atom: name} -> [name]
      {%{atom: "__MODULE__"}, _, _} -> module_alias(parent)
      _ -> []
    end
  end

  defp alias_names({%{atom: "__MODULE__"}, _, _}, parent), do: module_alias(parent)

  # `alias Base.{A, B.C}`: each item is relative to `Base`, so even a
  # one-segment item (`A`) names another module (`Base.A`) and is an alias.
  defp alias_names({{:., _, [_base, :{}]}, _, items}, _parent),
    do: Enum.flat_map(items, &multi_alias_item/1)

  defp alias_names(_other, _parent), do: []

  defp multi_alias_item({:__aliases__, _, parts}) do
    case List.last(parts) do
      %{atom: name} -> [name]
      _ -> []
    end
  end

  defp multi_alias_item(_other), do: []

  defp module_alias([_, _ | _] = parent), do: [List.last(parent)]
  defp module_alias(_parent), do: []

  @forbidden_kernel ~w(defmodule defimpl defprotocol)
  @forbidden_code ~w(compile_string compile_quoted compile_file require_file)
  @forbidden_erl_code ~w(load_binary load_file load_abs)

  defp forbidden_call({:__aliases__, _, parts}, %{atom: fun}) do
    case Enum.map(strip_elixir(parts), &segment_name/1) do
      ["Kernel"] when fun in @forbidden_kernel -> forbidden_message("Kernel.#{fun}")
      ["Kernel", "SpecialForms"] -> forbidden_message("Kernel.SpecialForms.#{fun}")
      ["Module"] when fun == "create" -> forbidden_message("Module.create")
      ["Code"] when fun in @forbidden_code -> forbidden_message("Code.#{fun}")
      _ -> nil
    end
  end

  defp forbidden_call(%{atom: "elixir_module"}, %{atom: fun}),
    do: forbidden_message(":elixir_module.#{fun}")

  defp forbidden_call(%{atom: "code"}, %{atom: fun}) when fun in @forbidden_erl_code,
    do: forbidden_message(":code.#{fun}")

  defp forbidden_call(_mod, _fun), do: nil

  defp forbidden_message(call) do
    "#{call} is not allowed in plugin sources: define modules with a plain defmodule, " <>
      "so beamdash can check their names before compiling"
  end

  defp segment_name(%{atom: name}), do: name
  defp segment_name(_), do: nil

  defp strip_elixir([%{atom: "Elixir"} | rest]), do: rest
  defp strip_elixir(parts), do: parts

  # defimpl Proto, for: X / for: [X, Y]; without for: (inside a module) it is
  # for the enclosing module.
  defp impl_targets([kw | _], _parent) when is_list(kw) do
    case Enum.find_value(kw, fn {k, v} -> if k == %{atom: "for"}, do: {:ok, v} end) do
      {:ok, list} when is_list(list) -> list
      {:ok, ast} -> [ast]
      nil -> [:parent]
    end
  end

  defp impl_targets(_rest, _parent), do: [:parent]

  defp resolve_targets(targets, parent) do
    Enum.reduce_while(targets, {:ok, []}, fn
      :parent, {:ok, acc} when parent != nil ->
        {:cont, {:ok, [parent | acc]}}

      :parent, _ ->
        {:halt, {:error, "a defimpl outside a module needs for:"}}

      ast, {:ok, acc} ->
        case absolute_name(ast, parent) do
          {:ok, name} -> {:cont, {:ok, [name | acc]}}
          error -> {:halt, error}
        end
    end)
    |> case do
      {:ok, []} -> {:error, "a defimpl needs a module in for:"}
      {:ok, names} -> {:ok, Enum.reverse(names)}
      error -> error
    end
  end

  # A defmodule/defprotocol name: nested names join their parent, unless they
  # start with Elixir. or __MODULE__.
  defp module_name({:__aliases__, _, [%{atom: "Elixir"} | _]} = ast, parent),
    do: absolute_name(ast, parent)

  defp module_name({:__aliases__, _, [{%{atom: "__MODULE__"}, _, _} | _]} = ast, parent),
    do: absolute_name(ast, parent)

  defp module_name({:__aliases__, _, parts}, parent) when is_list(parts) do
    with {:ok, segments} <- segments(parts), do: {:ok, (parent || []) ++ segments}
  end

  defp module_name(ast, parent), do: absolute_name(ast, parent)

  # A defimpl protocol or target name: never nested under the parent.
  defp absolute_name({:__aliases__, _, [%{atom: "Elixir"} | rest]}, _parent), do: segments(rest)

  defp absolute_name({:__aliases__, _, [{%{atom: "__MODULE__"}, _, _} | rest]}, parent)
       when parent != nil do
    with {:ok, segments} <- segments(rest, :allow_empty), do: {:ok, parent ++ segments}
  end

  defp absolute_name({:__aliases__, _, parts}, _parent) when is_list(parts), do: segments(parts)

  defp absolute_name({%{atom: "__MODULE__"}, _, ctx}, parent)
       when parent != nil and is_atom(ctx),
       do: {:ok, parent}

  defp absolute_name(%{atom: name}, _parent),
    do:
      {:error,
       "plugin modules must have Elixir names like MyPlugin.Page, not :#{String.slice(name, 0, 40)}"}

  defp absolute_name(_other, _parent), do: {:error, @not_alias_msg}

  defp segments(parts, empty \\ :refuse)
  defp segments([], :refuse), do: {:error, @not_alias_msg}

  defp segments(parts, _empty) do
    Enum.reduce_while(parts, {:ok, []}, fn
      %{atom: segment}, {:ok, acc} when is_binary(segment) ->
        if Regex.match?(@segment_re, segment),
          do: {:cont, {:ok, [segment | acc]}},
          else:
            {:halt,
             {:error, "invalid module name segment #{inspect(String.slice(segment, 0, 40))}"}}

      _, _ ->
        {:halt, {:error, @not_alias_msg}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp single_prefix(names) do
    case names |> Enum.map(&hd/1) |> Enum.uniq() do
      [prefix] ->
        {:ok, prefix}

      prefixes ->
        {:error,
         "all modules must share one top-level prefix, found #{Enum.join(prefixes, ", ")}"}
    end
  end

  defp no_clashes(modules, allow) do
    case Enum.filter(modules, &(&1 not in allow and taken?(&1))) do
      [] ->
        :ok

      taken ->
        {:error,
         "module #{taken |> Enum.map(&inspect/1) |> Enum.join(", ")} already exists in beamdash " <>
           "or on its code path; rename it under your plugin's prefix"}
    end
  end

  @doc false
  # Top-level names a plugin may never use as its prefix.
  @spec reserved_prefixes() :: [String.t()]
  def reserved_prefixes, do: ["Elixir", "Beamdash", "BeamdashWeb"]

  # The prefix must be the plugin's own namespace: no module that is loaded
  # or on the code path (other than `allow`, the plugin's own when it is
  # rebuilt) may be `Prefix` or `Prefix.*`.
  defp namespace_free(prefix, allow) do
    base = inspect(prefix)
    full = Atom.to_string(prefix)
    allowed = MapSet.new(allow, &Atom.to_string/1)

    names =
      Enum.map(:code.all_available(), fn {name, _, _} -> List.to_string(name) end) ++
        Enum.map(:code.all_loaded(), fn {module, _} -> Atom.to_string(module) end)

    used =
      names
      |> Enum.filter(
        &((&1 == full or String.starts_with?(&1, full <> ".")) and &1 not in allowed)
      )
      |> Enum.uniq()
      |> Enum.sort()

    cond do
      base in reserved_prefixes() or used != [] ->
        shown = used |> Enum.take(3) |> Enum.map(&module_label(String.to_atom(&1)))
        also = if shown == [], do: "", else: " (#{Enum.join(shown, ", ")})"

        {:error,
         "the prefix #{base} is already used by beamdash, Elixir or a library#{also}; " <>
           "name your plugin's modules under a top-level name of its own"}

      true ->
        :ok
    end
  end

  defp taken?(module),
    do: :code.is_loaded(module) != false or :code.which(module) != :non_existing

  defp prefix_defined(modules, prefix) do
    if prefix in modules,
      do: :ok,
      else:
        {:error,
         "the entry module #{inspect(prefix)} is not defined: every module must be under it, and it must exist"}
  end

  defp impl_modules(impls), do: for({proto, target} <- impls, do: Module.concat(proto ++ target))

  defp impls_under_prefix(impls, prefix) do
    case Enum.find(impls, fn {_proto, target} -> hd(target) != prefix end) do
      nil ->
        :ok

      {proto, target} ->
        {:error,
         "defimpl #{Enum.join(proto, ".")}, for: #{Enum.join(target, ".")} must be for a module under #{prefix}"}
    end
  end

  ## Compiling

  @doc """
  Compiles the plugin's `lib/**/*.ex` into `ebin` in this VM and returns the
  modules. `expected` is the module list from `scan/2` (by default the
  sources are scanned again). A compile that
  produces any other module is refused (the beams are left in `ebin` for the
  caller to delete).

  The compiler adds `ebin` to the code path while it runs; this removes it
  again afterwards, so plugin beams are never found ahead of beamdash's own.
  `load/2` loads them from the files. On failure the error is formatted as
  `file:line: message`, and only modules that came from `ebin` are purged.
  """
  @spec compile(Path.t(), Path.t(), [module()] | nil) ::
          {:ok, [module()]} | {:error, String.t()}
  def compile(src, ebin, expected \\ nil) do
    files = ex_files(src)
    expected = expected || scanned(src)
    loaded_before = loaded_set()

    result = run_compile(files, ebin)
    Code.delete_path(ebin)

    case result do
      {:ok, modules} ->
        case unexpected(modules, expected) do
          [] ->
            # Elixir < 1.19 leaves the compiled modules loaded; only load/2
            # may load them.
            unload_from(ebin, modules, loaded_before)
            {:ok, modules}

          extra ->
            unload_from(ebin, modules, loaded_before)

            {:error,
             "the compile produced modules the scan didn't find: #{labels(extra)}. " <>
               "Define every module with a plain defmodule under the plugin's prefix"}
        end

      {:error, message} ->
        unload_from(ebin, loaded_since(loaded_before), loaded_before)
        {:error, trim_message(message, src)}
    end
  end

  defp unexpected(modules, expected), do: modules -- expected

  # The modules the sources declare, as scan/2 finds them.
  defp scanned(src) do
    case scan_files(src) do
      {:ok, found} -> Enum.map(found.names, &Module.concat/1) ++ impl_modules(found.impls)
      {:error, _} -> []
    end
  end

  defp loaded_set, do: MapSet.new(:code.all_loaded(), &elem(&1, 0))

  defp loaded_since(before),
    do: for({m, _} <- :code.all_loaded(), not MapSet.member?(before, m), do: m)

  # Purges only modules that were not loaded before and whose code came from
  # `ebin` (or from memory, which is how the compiler loads them).
  defp unload_from(ebin, modules, loaded_before) do
    dir = Path.expand(ebin)

    modules
    |> Enum.reject(&MapSet.member?(loaded_before, &1))
    |> Enum.filter(fn module ->
      case :code.which(module) do
        path when is_list(path) -> path == [] or Path.dirname(List.to_string(path)) == dir
        _ -> false
      end
    end)
    |> unload()
  end

  defp run_compile(files, ebin) do
    with :ok <- File.mkdir_p(ebin) |> mkdir_result(ebin) do
      case Kernel.ParallelCompiler.compile_to_path(files, ebin, return_diagnostics: true) do
        {:ok, modules, _info} -> {:ok, modules}
        {:error, errors, _info} -> {:error, format_errors(errors)}
      end
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, "compilation failed: #{inspect({kind, reason})}"}
  end

  defp mkdir_result(:ok, _), do: :ok

  defp mkdir_result({:error, reason}, dir),
    do: {:error, "cannot create #{dir}: #{:file.format_error(reason)}"}

  # Diagnostic maps (newer Elixir) or {file, line, message} tuples (1.15).
  defp format_errors(errors) when is_list(errors) do
    errors
    |> Enum.map(fn
      %{file: file, position: position, message: message} ->
        location(file, position) <> clean(message)

      {file, line, message} ->
        location(file, line) <> clean(message)

      other ->
        inspect(other)
    end)
    |> Enum.join("\n")
  end

  defp format_errors(other), do: inspect(other)

  defp location(nil, _), do: ""
  defp location(file, {line, _col}), do: location(file, line)
  defp location(file, line) when is_integer(line) and line > 0, do: "#{file}:#{line}: "
  defp location(file, _), do: "#{file}: "

  defp clean(message) do
    message
    |> to_string()
    |> String.split("\n")
    |> Enum.reject(&Regex.match?(~r/\A\s+\((elixir|stdlib|kernel|erts)[^)]*\) /, &1))
    |> Enum.join("\n")
    |> String.trim()
  end

  defp trim_message(message, src) do
    message = String.replace(message, String.trim_trailing(src, "/") <> "/", "")

    if String.length(message) > @max_message,
      do: String.slice(message, 0, @max_message) <> "...",
      else: message
  end

  @doc """
  Kills the compiler workers of a `compile/3` that ran in `owner`, which has
  exited, and waits until they are gone. The workers aren't linked to the
  process that started the compile, so they would go on compiling, and
  loading, the plugin's modules. They are found by the compiler's
  `:elixir_compiler_info` process key (an Elixir internal; with no such key
  nothing is found).
  """
  @spec stop_compile(pid()) :: :ok
  def stop_compile(owner) when is_pid(owner) do
    workers =
      for pid <- Process.list(),
          pid != self(),
          {:dictionary, dict} <- [Process.info(pid, :dictionary)],
          match?({_, {^owner, _}}, List.keyfind(dict, :elixir_compiler_info, 0)),
          do: pid

    refs =
      for pid <- workers do
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)
        ref
      end

    for ref <- refs, do: receive(do: ({:DOWN, ^ref, :process, _, _} -> :ok))
    :ok
  end

  ## Checking

  @doc """
  Checks the compiled `modules` of a plugin with entry module `prefix`,
  reading the beams in `ebin` with `:beam_lib`. Nothing is loaded, and the
  code path is not changed. Returns the plugin map (`%{name:, pages:}`).

  Without `ebin`, the modules must already be loaded (the beams are found
  with `:code.which/1`).
  """
  @spec check([module()], module(), Path.t() | nil) :: {:ok, map()} | {:error, String.t()}
  def check(modules, prefix, ebin \\ nil) do
    with {:ok, beams} <- read_beams(modules, ebin),
         :ok <- all_under_prefix(beams, prefix),
         :ok <- one_entry(beams, prefix),
         {:ok, plugin} <- declaration(beams, prefix),
         :ok <- page_shapes(plugin, prefix),
         :ok <- valid_pages(plugin, beams),
         :ok <- imports_exist(beams) do
      {:ok, plugin}
    end
  end

  @doc """
  Loads the plugin's `modules` from the beams in `ebin`, with
  `:code.load_binary/3`, without adding `ebin` to the code path. A module
  that is already loaded from somewhere other than `ebin` is refused, and
  nothing is loaded.
  """
  @spec load([module()], Path.t()) :: :ok | {:error, String.t()}
  def load(modules, ebin) do
    dir = Path.expand(ebin)

    clash =
      Enum.filter(modules, fn module ->
        case :code.which(module) do
          :non_existing -> false
          path when is_list(path) and path != [] -> Path.dirname(List.to_string(path)) != dir
          _ -> true
        end
      end)

    if clash == [] do
      Enum.reduce_while(modules, :ok, fn module, :ok ->
        file = Path.join(dir, "#{module}.beam")

        with {:ok, binary} <- File.read(file),
             {:module, ^module} <- :code.load_binary(module, String.to_charlist(file), binary) do
          {:cont, :ok}
        else
          error ->
            unload(modules)
            {:halt, {:error, "could not load #{inspect(module)}: #{inspect(error)}"}}
        end
      end)
    else
      {:error, "modules already exist outside the plugin: #{labels(clash)}"}
    end
  end

  # module => %{exports:, imports:, impl_for:, forms_source}
  defp read_beams(modules, ebin) do
    Enum.reduce_while(modules, {:ok, %{}}, fn module, {:ok, acc} ->
      file =
        if ebin,
          do: String.to_charlist(Path.join(ebin, "#{module}.beam")),
          else: :code.which(module)

      case is_list(file) and file != [] and
             :beam_lib.chunks(file, [:exports, :imports, :attributes]) do
        {:ok, {^module, [exports: exports, imports: imports, attributes: attributes]}} ->
          impl = Keyword.get(attributes, :__impl__)
          info = %{file: file, exports: exports, imports: imports, impl: impl}
          {:cont, {:ok, Map.put(acc, module, info)}}

        _ ->
          {:halt, {:error, "the compiled beam of #{inspect(module)} could not be read"}}
      end
    end)
  end

  defp all_under_prefix(beams, prefix) do
    case beams |> Map.keys() |> Enum.reject(&under?(&1, prefix)) do
      [] ->
        :ok

      outside ->
        {:error, "modules outside #{inspect(prefix)}: #{labels(outside)}"}
    end
  end

  # A defimpl is named Protocol.Target: it is fine when Target is under the
  # prefix and the module is that name exactly (not trusting __impl__).
  defp under?(module, prefix) do
    named_under?(module, prefix) or
      Enum.any?(impl_names(module), fn {proto, target} ->
        Module.concat(proto, target) == module and named_under?(target, prefix)
      end)
  end

  defp named_under?(module, prefix) do
    name = Atom.to_string(module)
    base = Atom.to_string(prefix)
    name == base or String.starts_with?(name, base <> ".")
  end

  # Every split of "Elixir.A.B.C" into a protocol and a target.
  defp impl_names(module) do
    case Module.split(module) do
      parts when length(parts) >= 2 ->
        for i <- 1..(length(parts) - 1) do
          {Module.concat(Enum.take(parts, i)), Module.concat(Enum.drop(parts, i))}
        end

      _ ->
        []
    end
  rescue
    ArgumentError -> []
  end

  defp one_entry(beams, prefix) do
    case for({m, b} <- beams, {:__beamdash_plugin__, 0} in b.exports, do: m) do
      [^prefix] ->
        :ok

      [] ->
        {:error,
         "no module exports __beamdash_plugin__/0: #{inspect(prefix)} must `use Beamdash.Plugin`"}

      found ->
        {:error,
         "exactly one module, #{inspect(prefix)}, may `use Beamdash.Plugin`; found #{labels(found)} (__beamdash_plugin__/0)"}
    end
  end

  # `use Beamdash.Plugin` compiles __beamdash_plugin__/0 to "return this
  # literal map". The literal is read from the beam's code with
  # `:beam_disasm`, so the module is not loaded (and needs no debug info).
  defp declaration(beams, prefix) do
    case :beam_disasm.file(beams[prefix].file) do
      {:beam_file, ^prefix, _exports, _attrs, _info, code} ->
        bodies = for {:function, :__beamdash_plugin__, 0, _, body} <- code, do: body

        case Enum.flat_map(bodies, &returned_literal/1) do
          [%{name: name, pages: pages} = plugin] when is_binary(name) and is_list(pages) ->
            {:ok, plugin}

          _ ->
            declaration_error(prefix)
        end

      _ ->
        declaration_error(prefix)
    end
  rescue
    _ -> declaration_error(prefix)
  end

  defp returned_literal(body) do
    case Enum.drop_while(body, &(not match?({:move, {:literal, _}, {:x, 0}}, &1))) do
      [{:move, {:literal, value}, {:x, 0}}, :return | _] -> [value]
      _ -> []
    end
  end

  defp declaration_error(prefix) do
    {:error,
     "could not read the plugin declaration of #{inspect(prefix)}: it must `use Beamdash.Plugin`"}
  end

  # `use Beamdash.Plugin` checks the pages at compile time, but a
  # hand-written __beamdash_plugin__/0 skips that.
  defp page_shapes(%{pages: pages}, prefix) do
    case Enum.find(pages, &(not page_shape?(&1))) do
      nil ->
        :ok

      page ->
        {:error,
         "the plugin declaration of #{inspect(prefix)} has an invalid page: #{inspect(page)}. " <>
           "A page is %{slug: slug, label: string, module: module}, and the slug matches " <>
           ~S|\A[a-z][a-z0-9_-]{0,31}\z. `use Beamdash.Plugin` writes the declaration|}
    end
  end

  defp page_shape?(%{slug: slug, label: label, module: module}),
    do:
      Plugin.__valid_slug__?(slug) and is_binary(label) and is_atom(module) and
        module not in [nil, true, false]

  defp page_shape?(_), do: false

  defp valid_pages(plugin, beams) do
    bad =
      Enum.find_value(plugin.pages, fn %{module: page} ->
        cond do
          not Map.has_key?(beams, page) ->
            "page module #{inspect(page)} is not defined by the plugin"

          {:__live__, 0} not in beams[page].exports ->
            "page module #{inspect(page)} must `use Beamdash.Plugin.Page`"

          true ->
            nil
        end
      end)

    if bad, do: {:error, bad}, else: :ok
  end

  defp imports_exist(beams) do
    missing =
      beams
      |> Enum.flat_map(fn {_m, b} -> for {mod, _f, _a} <- b.imports, do: mod end)
      |> Enum.uniq()
      |> Enum.reject(&(Map.has_key?(beams, &1) or taken?(&1)))

    case missing do
      [] ->
        :ok

      missing ->
        {:error,
         "calls modules beamdash doesn't have: #{labels(missing)}. " <>
           "Call the attached node's modules with Beamdash.Plugin.rpc/4"}
    end
  end

  defp labels(modules), do: modules |> Enum.map(&module_label/1) |> Enum.sort() |> Enum.join(", ")

  defp module_label(module) do
    case Atom.to_string(module) do
      "Elixir." <> _ -> inspect(module)
      name -> name
    end
  end
end
