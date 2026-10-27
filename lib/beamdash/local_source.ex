defmodule Beamdash.LocalSource do
  @moduledoc """
  Finds a module's source file on this computer, for modules whose source
  isn't on the node: a release (in a Kubernetes pod, say) usually has
  neither the source files nor debug info. Settings maps an application to
  a local folder (`Beamdash.Settings.source_dirs/0`).

  The node says which application the module belongs to
  (`application:get_application/1`) and the path it was compiled from (its
  compile info). That application's folder is searched, or every folder
  when it has none set:

    1. for the compile path's tail: `/build/apps/my_app/src/my_mod.erl`
       matches `<folder>/apps/my_app/src/my_mod.erl`, then
       `<folder>/my_app/src/my_mod.erl`, and so on down to the file name;
    2. else for a file of that name anywhere under the folder (outside
       `_build` and `deps` when there is a choice), the shortest path first.
       An Erlang module with no compile path is looked for as `<mod>.erl`.

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
      case by_tail(dir, remote) || by_name(dir, file_name(mod, remote)) do
        nil -> nil
        path -> {:ok, path}
      end
    end)
  end

  defp folders(node, mod, dirs, rpc) do
    app =
      case rpc.(node, :application, :get_application, [mod]) do
        {:ok, {:ok, app}} when is_atom(app) -> Atom.to_string(app)
        _ -> nil
      end

    case dirs do
      %{^app => dir} -> [dir]
      _ -> dirs |> Map.values() |> Enum.uniq()
    end
  end

  defp remote_path(node, mod, rpc) do
    with {:ok, compile} when is_list(compile) <- rpc.(node, mod, :module_info, [:compile]),
         source when is_list(source) <- Keyword.get(compile, :source) do
      List.to_string(source)
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
      "Elixir." <> _ -> nil
      name -> name <> ".erl"
    end
  end

  defp by_name(_dir, nil), do: nil

  defp by_name(dir, name) do
    found =
      dir
      |> Path.join("**/" <> name)
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)

    {built, own} = Enum.split_with(found, &(&1 =~ ~r{/(_build|deps)/}))
    Enum.min_by(if(own != [], do: own, else: built), &String.length/1, fn -> nil end)
  end
end
