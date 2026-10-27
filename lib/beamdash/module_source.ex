defmodule Beamdash.ModuleSource do
  @moduledoc """
  The source of a module loaded on the attached node, read there
  (`beamdash_agent:module_source/1`): the file its compile info names, or
  Erlang source rebuilt from its debug info when that file isn't on the
  node.
  """

  alias Beamdash.Target

  @timeout 15_000

  @doc """
  `{:ok, %{kind, path, text, truncated}}`, where `kind` is `:file` (the
  source file) or `:debug_info` (rebuilt as Erlang), `path` the source path
  the module was compiled from (`nil` if unknown); `{:ok, %{kind: :none,
  path, reason}}` when there is neither; or `{:error, reason}`.
  """
  def get(node, mod) when is_atom(mod) do
    case Target.rpc(node, :beamdash_agent, :module_source, [mod], @timeout) do
      {:ok, %{path: :undefined} = source} -> {:ok, %{source | path: nil}}
      {:ok, source} -> {:ok, source}
      error -> error
    end
  end

  @doc """
  Whether `get/2` has a source to show for `mod`: its source file is on
  the node, or its beam has debug info. Usually neither on a release (in a
  Kubernetes pod, say). `false` when the node can't be asked.
  """
  def available?(nil, _mod), do: false

  def available?(node, mod) when is_atom(mod) do
    Target.rpc(node, :beamdash_agent, :source_available, [mod]) == {:ok, true}
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
