defmodule Beamdash.AgentLoader do
  @moduledoc """
  Loads helper modules (`:beamdash_agent`, `:erlyberly`) into a target node.

  The agent is compiled on this machine. If the target runs an older
  Erlang/OTP that refuses the compiled BEAM, we recompile the module's
  abstract code here for the target's release (the compiler's `r25`..`r27`
  options), so the target needs no `compiler` application, which releases
  often leave out. Only when that fails too (a release those options do not
  cover) do we send the abstract code and let the target compile it.
  """

  @doc "Makes sure the current version of `module` is loaded on `node`."
  @spec ensure_loaded(
          node(),
          (node(), module(), atom(), list() -> {:ok, term()} | {:error, term()}),
          module()
        ) ::
          :ok | {:error, term()}
  def ensure_loaded(node, rpc, module \\ :beamdash_agent) do
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
      {:ok, {:error, _reason}} -> load_for_release(node, mod, bin, file, rpc)
      {:error, reason} -> {:error, {:agent_load_failed, reason}}
    end
  end

  # The md5 check keeps a reconnect from reloading the same recompiled
  # module, which would fail with not_purged while agent processes still
  # run the code it would make old.
  defp load_for_release(node, mod, bin, file, rpc) do
    with {:ok, forms} <- abstract_forms(bin),
         {:ok, option} <- release_option(node, rpc),
         {:ok, ^mod, release_bin} <- :compile.forms(forms, [:binary, :return_errors, option]),
         :ok <- load_unless_loaded(node, mod, file, release_bin, rpc) do
      :ok
    else
      _ -> compile_on_target(node, mod, bin, file, rpc)
    end
  end

  defp load_unless_loaded(node, mod, file, bin, rpc) do
    cond do
      loaded?(node, bin, rpc) -> :ok
      rpc.(node, :code, :load_binary, [mod, file, bin]) == {:ok, {:module, mod}} -> :ok
      true -> :error
    end
  end

  # `rNN` makes the compiler emit only what OTP NN can load; it knows these
  # for releases older than its own, back to 25.
  defp release_option(node, rpc) do
    with {:ok, release} when is_list(release) <-
           rpc.(node, :erlang, :system_info, [:otp_release]),
         {n, ""} when n >= 25 <- Integer.parse(List.to_string(release)),
         true <- n < String.to_integer(List.to_string(:erlang.system_info(:otp_release))) do
      {:ok, String.to_atom("r#{n}")}
    else
      _ -> :error
    end
  end

  defp abstract_forms(bin) do
    case :beam_lib.chunks(bin, [:abstract_code]) do
      {:ok, {_, [abstract_code: {:raw_abstract_v1, forms}]}} -> {:ok, forms}
      _ -> :error
    end
  end

  defp compile_on_target(node, mod, bin, file, rpc) do
    with {:ok, forms} <- abstract_forms(bin),
         {:ok, {:ok, ^mod, remote_bin}} <-
           rpc.(node, :compile, :forms, [forms, [:binary, :return_errors]]),
         {:ok, {:module, ^mod}} <- rpc.(node, :code, :load_binary, [mod, file, remote_bin]) do
      :ok
    else
      other -> {:error, {:agent_load_failed, other}}
    end
  end
end
