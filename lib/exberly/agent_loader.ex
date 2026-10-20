defmodule Exberly.AgentLoader do
  @moduledoc """
  Loads helper modules (`:exberly_agent`, `:erlyberly`) into a target node.

  The agent is compiled on this machine. If the target runs an older
  Erlang/OTP that refuses the compiled BEAM, we send the module's abstract
  code instead and let the target compile it with its own compiler.
  """

  @doc "Makes sure the current version of `module` is loaded on `node`."
  @spec ensure_loaded(
          node(),
          (node(), module(), atom(), list() -> {:ok, term()} | {:error, term()}),
          module()
        ) ::
          :ok | {:error, term()}
  def ensure_loaded(node, rpc, module \\ :exberly_agent) do
    with {:ok, mod, bin, file} <- local_object_code(module) do
      if loaded?(node, bin, rpc) do
        :ok
      else
        load(node, mod, bin, file, rpc)
      end
    end
  end

  defp local_object_code(module) do
    case :code.get_object_code(module) do
      {mod, bin, file} -> {:ok, mod, bin, file}
      :error -> {:error, {:agent_not_found, module}}
    end
  end

  defp loaded?(node, bin, rpc) do
    {:ok, {mod, local_md5}} = :beam_lib.md5(bin)

    case rpc.(node, mod, :module_info, [:md5]) do
      {:ok, ^local_md5} -> true
      _ -> false
    end
  end

  defp load(node, mod, bin, file, rpc) do
    case rpc.(node, :code, :load_binary, [mod, file, bin]) do
      {:ok, {:module, ^mod}} -> :ok
      {:ok, {:error, _reason}} -> compile_on_target(node, mod, bin, file, rpc)
      {:error, reason} -> {:error, {:agent_load_failed, reason}}
    end
  end

  defp compile_on_target(node, mod, bin, file, rpc) do
    with {:ok, {_, [abstract_code: {:raw_abstract_v1, forms}]}} <-
           :beam_lib.chunks(bin, [:abstract_code]),
         {:ok, {:ok, ^mod, remote_bin}} <-
           rpc.(node, :compile, :forms, [forms, [:binary, :return_errors]]),
         {:ok, {:module, ^mod}} <- rpc.(node, :code, :load_binary, [mod, file, remote_bin]) do
      :ok
    else
      other -> {:error, {:agent_load_failed, other}}
    end
  end
end
