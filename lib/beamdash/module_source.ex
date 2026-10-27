defmodule Beamdash.ModuleSource do
  @moduledoc """
  The source of a module loaded on the attached node, read there
  (`beamdash_agent:module_source/1`): the file its compile info names.
  When that file isn't on the node, a file found on this computer under
  the application's source folder from Settings (`Beamdash.LocalSource`),
  or else Erlang source rebuilt from the module's debug info.
  """

  alias Beamdash.{LocalSource, Target}

  @timeout 15_000
  # as the agent limits a node's file
  @max_source 2 * 1024 * 1024

  @doc """
  `{:ok, %{kind, path, text, truncated}}`, where `kind` is `:file` (the
  source file on the node), `:local` (a file on this computer, `path` being
  its local path) or `:debug_info` (rebuilt as Erlang), `path` otherwise
  the source path the module was compiled from (`nil` if unknown);
  `{:ok, %{kind: :none, path, reason}}` when there is none of these; or
  `{:error, reason}`.
  """
  def get(node, mod, find_local \\ &LocalSource.find/2) when is_atom(mod) do
    case Target.rpc(node, :beamdash_agent, :module_source, [mod], @timeout) do
      {:ok, %{kind: :file} = source} -> {:ok, source}
      {:ok, source} -> {:ok, local(node, mod, find_local) || nil_path(source)}
      error -> error
    end
  end

  defp nil_path(%{path: :undefined} = source), do: %{source | path: nil}
  defp nil_path(source), do: source

  defp local(node, mod, find_local) do
    with {:ok, path} <- find_local.(node, mod),
         {:ok, bin} <- File.read(path) do
      truncated = byte_size(bin) > @max_source
      text = if truncated, do: binary_part(bin, 0, @max_source), else: bin
      %{kind: :local, path: path, text: text, truncated: truncated}
    else
      _ -> nil
    end
  end

  @doc """
  Whether `get/2` has a source to show for `mod`: its source file is on
  the node, its beam has debug info (usually neither on a release, in a
  Kubernetes pod, say), or a local source folder has it. `false` when the
  node can't be asked.
  """
  def available?(node, mod, find_local \\ &LocalSource.find/2)

  def available?(nil, _mod, _find_local), do: false

  def available?(node, mod, find_local) when is_atom(mod) do
    case Target.rpc(node, :beamdash_agent, :source_available, [mod]) do
      {:ok, true} -> true
      {:ok, false} -> match?({:ok, _}, find_local.(node, mod))
      _ -> false
    end
  end

  @doc "Why a module has no source to show, in words."
  def reason(:no_debug_info),
    do: "its source file isn't on the node, and it was compiled without debug info"

  def reason(:preloaded), do: "it is preloaded into the runtime, without a beam file"
  def reason(:not_loaded), do: "it isn't loaded on the node"

  def reason(:no_beam_file),
    do: "its source file isn't on the node, and it was loaded without a beam file"

  def reason(other), do: "its debug info can't be read: #{inspect(other)}"
end
