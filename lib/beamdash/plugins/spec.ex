defmodule Beamdash.Plugins.Spec do
  @moduledoc """
  Parses the text a user types in Settings to add a plugin: a Mix
  dependency written as in `mix.exs`, for example

      {:riak_core_plugin, "~> 0.1"}
      {:riak_core_plugin, git: "https://github.com/o/r", tag: "0.0.1"}
      {:riak_core_plugin, github: "o/r", branch: "main"}
      {:riak_core_plugin, path: "~/projects/riak_core_plugin"}
      {:riak_core_plugin, "~> 0.1", hex: :other_package}

  The text is **never evaluated**. It is read with `Code.string_to_quoted/2`
  and the syntax tree is walked, accepting only literals (atoms, strings,
  tuples and keyword lists). Anything else, such as a call, a variable, a
  sigil or an interpolation, is refused. The parser is given a
  `:static_atoms_encoder`, so it cannot create atoms from the text; the only
  atom made is the app name, after it passes `^[a-z][a-z0-9_]{0,63}$`.

  `parse/1` returns `{:ok, spec}` or `{:error, message}` (a short sentence for
  the Settings form). `to_string/1` writes a spec back in Mix syntax, and
  `parse(to_string(spec))` returns the same spec.

  `config :beamdash, :plugins_allow_local_git, true` lets a `git:` value be a
  local path or a `file://` URL. It is for tests only.
  """

  import Kernel, except: [to_string: 1]

  @type ref :: {:tag | :branch | :ref, String.t()}
  @type t :: %{
          app: atom(),
          source: :hex | :git | :path,
          requirement: String.t() | nil,
          package: String.t(),
          url: String.t() | nil,
          github: String.t() | nil,
          ref: ref() | nil,
          path: String.t() | nil
        }

  @max_bytes 4_000
  @max_value 500
  # \A and \z, not ^ and $: in PCRE `$` also matches before a final "\n".
  @app_re ~r/\A[a-z][a-z0-9_]{0,63}\z/
  # An ssh host (or user@host) never starts with "-", so it cannot be read as a git option.
  @git_url_re ~r{\A(https://|ssh://(?!-)(?![^/@\s]*@-)|git@(?!-)[^:\s]+:)\S+\z}
  @local_git_re ~r{\A(file://|/)\S+\z}
  @github_re ~r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}
  @ref_re ~r{\A[^\s-]\S*\z}
  @ref_kinds %{"tag" => :tag, "branch" => :branch, "ref" => :ref}
  @version_hint_re ~r/\{\s*:([a-z][a-z0-9_]*)\s*,\s*(\d+\.\d+(?:\.\d+)?)\s*\}/
  @url_hint_re ~r{git:\s*(https?://|git@|ssh://)}
  @allowed ~w(git github path hex tag branch ref)
  @sources ~w(git github path hex)

  @syntax_hint ~S|use mix.exs dependency syntax, e.g. {:my_plugin, "~> 0.1"}|
  @literal_msg "only literal values are allowed (strings, atoms, tuples and keyword lists)"

  @doc "Whether a `git:` value may be a local path or `file://` URL (tests only)."
  @spec allow_local_git?() :: boolean()
  def allow_local_git?, do: Application.get_env(:beamdash, :plugins_allow_local_git, false)

  @doc "Parses and validates dependency text without evaluating it."
  @spec parse(term()) :: {:ok, t()} | {:error, String.t()}
  def parse(text) when is_binary(text) do
    cond do
      byte_size(text) > @max_bytes -> {:error, "the dependency is too long"}
      not String.valid?(text) -> {:error, @syntax_hint}
      true -> parse_text(String.trim(text))
    end
  end

  def parse(_), do: {:error, @syntax_hint}

  @doc "Writes a spec back in Mix syntax."
  @spec to_string(t()) :: String.t()
  def to_string(%{source: :hex} = spec) do
    app = inspect(spec.app)
    req = inspect(spec.requirement)

    if spec.package == Atom.to_string(spec.app),
      do: "{#{app}, #{req}}",
      # `package` passed @app_re in parse/1, so this atom is bounded.
      else: "{#{app}, #{req}, hex: #{inspect(String.to_atom(spec.package))}}"
  end

  def to_string(%{source: :git} = spec) do
    source =
      if spec.github,
        do: "github: #{inspect(spec.github)}",
        else: "git: #{inspect(spec.url)}"

    ref =
      case spec.ref do
        nil -> ""
        {kind, value} -> ", #{kind}: #{inspect(value)}"
      end

    "{#{inspect(spec.app)}, #{source}#{ref}}"
  end

  def to_string(%{source: :path} = spec),
    do: "{#{inspect(spec.app)}, path: #{inspect(spec.path)}}"

  # --- parsing ---------------------------------------------------------

  defp parse_text(text) do
    case quote_text(text) do
      {:ok, ast} -> from_ast(ast, text)
      :error -> {:error, hint(text) || @syntax_hint}
    end
  end

  # Atoms come back as `%{atom: string}` (a map never appears in a literal
  # AST), so the parser creates none and atoms stay distinct from strings.
  defp quote_text(text) do
    encoder = fn token, _meta -> {:ok, %{atom: token}} end

    # `emit_warnings: false` needs Elixir 1.16+; 1.15 ignores it, which only
    # means a quoted-keyword warning may be printed to stderr.

    case Code.string_to_quoted(text, static_atoms_encoder: encoder, emit_warnings: false) do
      {:ok, ast} -> {:ok, ast}
      {:error, _} -> :error
    end
  rescue
    # e.g. an unquoted `https://...`: the tokenizer cannot use a map as a name.
    _ -> :error
  end

  defp from_ast(ast, text) do
    case top_level(ast) do
      :syntax ->
        {:error, @syntax_hint}

      :many ->
        {:error, "give one dependency only"}

      :tuple ->
        case literal(ast) do
          {:ok, term} -> build(term)
          :error -> {:error, hint(text) || @literal_msg}
        end

      :other ->
        {:error, hint(text) || @literal_msg}
    end
  end

  defp top_level({:__block__, _, []}), do: :syntax
  defp top_level({:__block__, _, [_, _ | _]}), do: :many
  defp top_level({_, _}), do: :tuple
  defp top_level({:{}, _, items}) when is_list(items), do: :tuple
  defp top_level(%{atom: _}), do: :syntax
  defp top_level(bin) when is_binary(bin), do: :syntax
  defp top_level(list) when is_list(list), do: :syntax
  defp top_level({%{atom: _}, _, ctx}) when is_atom(ctx), do: :syntax
  defp top_level(_), do: :other

  defp hint(text) do
    cond do
      match = Regex.run(@version_hint_re, text) ->
        [_, name, version] = match
        ~s|write the version as a string, as in mix.exs: {:#{name}, "#{version}"}|

      Regex.match?(@url_hint_re, text) ->
        ~S|put the URL in quotes: git: "https://…"|

      true ->
        nil
    end
  end

  # Normalised literals: atoms are {:a, string}, 3+ element tuples are
  # {:tuple, items}, strings and booleans/nil stay as they are.
  defp literal(%{atom: name}) when is_binary(name), do: {:ok, {:a, name}}
  defp literal(v) when is_binary(v) or is_boolean(v) or is_nil(v), do: {:ok, v}
  defp literal(list) when is_list(list), do: literal_list(list, [])

  defp literal({a, b}) do
    with {:ok, a} <- literal(a), {:ok, b} <- literal(b), do: {:ok, {a, b}}
  end

  defp literal({:{}, _, items}) when is_list(items) do
    with {:ok, items} <- literal_list(items, []), do: {:ok, {:tuple, items}}
  end

  defp literal(_), do: :error

  defp literal_list([], acc), do: {:ok, Enum.reverse(acc)}

  defp literal_list([h | t], acc) do
    with {:ok, h} <- literal(h), do: literal_list(t, [h | acc])
  end

  # --- validation ------------------------------------------------------

  defp build({:tuple, [app, req, opts]}) when is_binary(req) and is_list(opts),
    do: validate(app, req, opts)

  defp build({app, req}) when is_binary(req), do: validate(app, req, [])
  defp build({app, opts}) when is_list(opts), do: validate(app, nil, opts)
  defp build(_), do: {:error, @syntax_hint}

  defp validate(app, req, opts) do
    with {:ok, app} <- check_app(app),
         {:ok, kv} <- keyword(opts),
         :ok <- check_keys(kv),
         {:ok, source} <- pick_source(kv, req),
         :ok <- check_requirement(req),
         {:ok, spec} <- build_source(source, kv, req) do
      {:ok, finish(spec, app)}
    end
  end

  defp finish(spec, app) do
    spec = Map.put(spec, :app, String.to_atom(app))
    if spec.package == nil, do: %{spec | package: app}, else: spec
  end

  defp check_app({:a, name}) when is_binary(name) do
    if Regex.match?(@app_re, name),
      do: {:ok, name},
      else: {:error, "invalid app name #{show(name)}: use lowercase letters, digits and _"}
  end

  defp check_app(_), do: {:error, "invalid app name: it must be an atom like :my_plugin"}

  defp keyword(opts) do
    Enum.reduce_while(opts, {:ok, []}, fn
      {{:a, key}, value}, {:ok, acc} ->
        if List.keymember?(acc, key, 0),
          do: {:halt, {:error, "#{key}: is given twice"}},
          else: {:cont, {:ok, acc ++ [{key, value}]}}

      _, _ ->
        {:halt, {:error, ~S|the options must be a keyword list, like git: "url"|}}
    end)
  end

  defp check_keys(kv) do
    case Enum.find(kv, fn {key, _} -> key not in @allowed end) do
      nil ->
        :ok

      {key, _} ->
        {:error, "unsupported option #{show(key)}; use one of #{Enum.join(@allowed, ", ")}"}
    end
  end

  defp pick_source(kv, req) do
    case Enum.filter(kv, fn {key, _} -> key in @sources end) do
      [{key, _}] when req != nil and key != "hex" ->
        {:error, "a version requirement only goes with a Hex package, not #{key}:"}

      [{key, _}] ->
        {:ok, key}

      [] when req != nil ->
        {:ok, "hex"}

      _ ->
        {:error, "give exactly one source: a version, git:, github:, path: or hex:"}
    end
  end

  defp check_requirement(nil), do: :ok

  defp check_requirement(req) do
    with :ok <- printable(req, "the version requirement") do
      case Version.parse_requirement(req) do
        {:ok, _} -> :ok
        :error -> {:error, "invalid version requirement #{show(req)}, e.g. \"~> 0.1\""}
      end
    end
  end

  defp build_source("hex", kv, req) do
    with :ok <- no_refs(kv, "hex"),
         {:ok, package} <- hex_package(kv) do
      if req == nil,
        do: {:error, "hex: needs a version requirement, e.g. {:p, \"~> 0.1\", hex: :name}"},
        else: {:ok, base(:hex, %{requirement: req, package: package})}
    end
  end

  defp build_source("path", kv, _req) do
    with :ok <- no_refs(kv, "path"),
         {:ok, path} <- string(kv, "path"),
         :ok <- not_empty(path, "path:") do
      {:ok, base(:path, %{path: Path.expand(path)})}
    end
  end

  defp build_source(key, kv, _req) when key in ["git", "github"] do
    with {:ok, value} <- string(kv, key),
         {:ok, url, github} <- git_url(key, value),
         {:ok, ref} <- git_ref(kv) do
      {:ok, base(:git, %{url: url, github: github, ref: ref})}
    end
  end

  defp base(source, extra) do
    Map.merge(
      %{
        source: source,
        requirement: nil,
        package: nil,
        url: nil,
        github: nil,
        ref: nil,
        path: nil
      },
      extra
    )
  end

  defp hex_package(kv) do
    case List.keyfind(kv, "hex", 0) do
      nil ->
        {:ok, nil}

      {_, {:a, name}} ->
        if Regex.match?(@app_re, name),
          do: {:ok, name},
          else: {:error, "invalid hex package name #{show(name)}"}

      _ ->
        {:error, "hex: must be a package name like :my_package"}
    end
  end

  defp git_url("github", value) do
    if Regex.match?(@github_re, value) and byte_size(value) <= @max_value,
      do: {:ok, "https://github.com/#{value}.git", value},
      else: {:error, ~S|github: must be "owner/repo"|}
  end

  defp git_url("git", value) do
    if byte_size(value) <= @max_value and
         (Regex.match?(@git_url_re, value) or
            (allow_local_git?() and Regex.match?(@local_git_re, value))) do
      {:ok, value, nil}
    else
      {:error, "the git URL must start with https://, ssh:// or git@host:"}
    end
  end

  defp git_ref(kv) do
    case Enum.filter(kv, fn {key, _} -> Map.has_key?(@ref_kinds, key) end) do
      [] ->
        {:ok, nil}

      [{key, _}] ->
        with {:ok, value} <- string(kv, key) do
          if Regex.match?(@ref_re, value) and byte_size(value) <= @max_value,
            do: {:ok, {Map.get(@ref_kinds, key), value}},
            else: {:error, "#{key}: must be a name without spaces, not starting with -"}
        end

      _ ->
        {:error, "use at most one of tag, branch or ref"}
    end
  end

  defp no_refs(kv, source) do
    case Enum.find(kv, fn {key, _} -> Map.has_key?(@ref_kinds, key) end) do
      nil -> :ok
      {key, _} -> {:error, "#{key}: only works with git: or github:, not #{source}:"}
    end
  end

  defp string(kv, key) do
    case List.keyfind(kv, key, 0) do
      {_, value} when is_binary(value) ->
        with :ok <- printable(value, "#{key}:"), do: {:ok, value}

      _ ->
        {:error, "#{key}: must be a quoted string"}
    end
  end

  defp not_empty("", label), do: {:error, "#{label} must not be empty"}
  defp not_empty(_, _), do: :ok

  defp printable(value, label) do
    if String.printable?(value), do: :ok, else: {:error, "#{label} has unprintable characters"}
  end

  defp show(value), do: value |> String.slice(0, 40) |> inspect()
end
