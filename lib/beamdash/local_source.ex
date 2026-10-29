defmodule Beamdash.LocalSource do
  @moduledoc """
  Finds a module's source file on this computer, for modules whose source
  isn't on the node: a release (in a Kubernetes pod, say) usually has
  neither the source files nor debug info. Settings maps an application to
  a local folder (`Beamdash.Settings.source_dirs/0`).

  The node says which application the module belongs to
  (`application:get_application/1`) and the path it was compiled from (its
  compile info). That application's folder is searched first, followed by
  the remaining configured folders in application-name order:

    1. for the compile path's tail: `/build/apps/my_app/src/my_mod.erl`
       matches `<folder>/apps/my_app/src/my_mod.erl`, then
       `<folder>/my_app/src/my_mod.erl`, and so on down to the file name;
    2. else for a file of that name anywhere under the folder (outside
       `_build` and `deps` when there is a choice), the shortest path first.
       An Erlang module with no compile path is looked for as `<mod>.erl`;
       an Elixir module uses its conventional underscored path, such as
       `my_app/worker.ex` for `MyApp.Worker`;
    3. for Elixir, parse local `.ex` and `.exs` files to find the module's
       declaration when filenames do not match. All subfolders, including
       `deps` and `_build`, are searched recursively, following directory links
       without looping. Project source is preferred over dependency/build copies.
       Source is never evaluated.

  The file found is what is on this computer now, which need not be the
  version the node runs.
  """

  alias Beamdash.{Settings, Target}

  @doc """
  `{:ok, path}` of `mod`'s source under the configured folders, or `:error`.
  `rpc` is `Beamdash.Target.rpc/4`'s shape.
  """
  def find(node, mod, dirs \\ Settings.source_dirs(), rpc \\ &Target.rpc/4)

  def find(_node, _mod, dirs, _rpc) when dirs == %{}, do: :error

  def find(node, mod, dirs, rpc) when is_atom(mod) do
    remote = remote_path(node, mod, rpc)

    node
    |> folders(mod, dirs, rpc)
    |> Enum.find_value(:error, fn dir ->
      path = by_tail(dir, remote) || search_tree(dir, mod, remote)
      if path, do: {:ok, path}
    end)
  end

  @doc "The local Mix project containing a source file, using the root for standard umbrellas."
  def project_dir(path) when is_binary(path) do
    if File.regular?(path), do: path |> Path.expand() |> Path.dirname() |> nearest_project()
  end

  def project_dir(_), do: nil

  defp nearest_project(dir) do
    parent = Path.dirname(dir)

    cond do
      File.regular?(Path.join(dir, "mix.exs")) ->
        umbrella = Path.dirname(parent)

        if Path.basename(parent) == "apps" and File.regular?(Path.join(umbrella, "mix.exs")),
          do: umbrella,
          else: dir

      parent == dir ->
        nil

      true ->
        nearest_project(parent)
    end
  end

  defp folders(node, mod, dirs, rpc) do
    app =
      case rpc.(node, :application, :get_application, [mod]) do
        {:ok, {:ok, app}} when is_atom(app) -> Atom.to_string(app)
        _ -> nil
      end

    preferred = Map.get(dirs, app)
    remaining = dirs |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
    ([preferred] ++ remaining) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  defp remote_path(node, mod, rpc) do
    with {:ok, compile} when is_list(compile) <- rpc.(node, mod, :module_info, [:compile]),
         source when is_list(source) or is_binary(source) <- Keyword.get(compile, :source) do
      IO.chardata_to_string(source)
    else
      _ -> nil
    end
  end

  defp by_tail(_dir, nil), do: nil

  defp by_tail(dir, remote) do
    parts = remote |> Path.split() |> Enum.reject(&(&1 == "/"))

    0..(length(parts) - 1)//1
    |> Enum.map(&Path.join([dir | Enum.drop(parts, &1)]))
    |> Enum.find(&File.regular?/1)
  end

  defp file_name(_mod, remote) when is_binary(remote), do: Path.basename(remote)

  defp file_name(mod, nil) do
    case Atom.to_string(mod) do
      "Elixir." <> name -> Macro.underscore(name) <> ".ex"
      name -> name <> ".erl"
    end
  end

  defp search_tree(dir, mod, remote) do
    conventional = file_name(mod, nil)
    remote_name = file_name(mod, remote)
    extensions = Enum.uniq([".ex", ".exs", Path.extname(conventional), Path.extname(remote_name)])
    {files, _} = source_files(dir, MapSet.new(), extensions)
    files = Enum.sort_by(files, &{source_rank(&1, dir), String.length(&1), &1})

    by_name(files, remote_name) || by_tail(dir, conventional) ||
      by_name(files, conventional) || by_declaration(files, mod)
  end

  defp by_name(files, name), do: Enum.find(files, &String.ends_with?(&1, "/" <> name))

  defp source_rank(path, dir) do
    parts = path |> Path.relative_to(dir) |> Path.split()

    cond do
      "_build" in parts -> 2
      "deps" in parts -> 1
      true -> 0
    end
  end

  # Follow directory links, tracking filesystem identities rather than path
  # strings so links back to a parent cannot create an endless recursion.
  defp source_files(path, seen, extensions) do
    case File.stat(path) do
      {:ok, %{type: :directory} = stat} ->
        identity = {stat.major_device, stat.minor_device, stat.inode}

        if MapSet.member?(seen, identity) do
          {[], seen}
        else
          seen = MapSet.put(seen, identity)

          case File.ls(path) do
            {:ok, names} ->
              names
              |> Enum.sort_by(&{source_rank(Path.join(path, &1), path), &1})
              |> Enum.reduce({[], seen}, fn name, {files, visited} ->
                {found, visited} = source_files(Path.join(path, name), visited, extensions)
                {found ++ files, visited}
              end)

            _ ->
              {[], seen}
          end
        end

      {:ok, %{type: :regular}} ->
        if Path.extname(path) in extensions, do: {[path], seen}, else: {[], seen}

      _ ->
        {[], seen}
    end
  end

  # Filenames are a convention, not a requirement (VNode can live in vnode.ex,
  # and a file may define several modules). Parse only: never evaluate source.
  defp by_declaration(files, mod) do
    case Atom.to_string(mod) do
      "Elixir." <> expected ->
        files
        |> Enum.filter(&(Path.extname(&1) in [".ex", ".exs"]))
        |> Enum.find(fn path ->
          with {:ok, %{size: size}} when size <= 2 * 1024 * 1024 <- File.stat(path),
               {:ok, text} <- File.read(path),
               {:ok, ast} <- Code.string_to_quoted(text) do
            declares?(ast, expected, [])
          else
            _ -> false
          end
        end)

      _ ->
        nil
    end
  end

  defp declares?({:defmodule, _, [{:__aliases__, _, parts}, body]}, expected, parent) do
    parts = Enum.map(parts, &Atom.to_string/1)

    name =
      case parts do
        ["Elixir" | absolute] -> absolute
        relative -> parent ++ relative
      end

    Enum.join(name, ".") == expected or declares?(body, expected, name)
  end

  defp declares?(tuple, expected, parent) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.any?(&declares?(&1, expected, parent))

  defp declares?(list, expected, parent) when is_list(list),
    do: Enum.any?(list, &declares?(&1, expected, parent))

  defp declares?(_, _, _), do: false
end
