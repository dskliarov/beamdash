defmodule Exberly.Memory do
  @moduledoc """
  Memory of the connected node: `erlang:memory()` snapshots and the leak
  investigation behind the Memory page, through `exberly_agent`.

  recon (a dependency of exberly) is used for the investigation when it
  can be: if the node has its own recon, that one; otherwise exberly loads
  its copy (`recon`, `recon_lib`, `recon_alloc`) into the node, but never
  over the node's own. If neither is possible the agent's built-in
  equivalents are used. `recon_status/1` says which.
  """

  alias Exberly.{AgentLoader, Target}

  @recon_modules [:recon_lib, :recon, :recon_alloc]
  @timeout 30_000

  @doc """
  Makes recon usable on `node` if possible. Returns `:node` (the node has
  its own), `:loaded` (exberly's copy, loaded now or earlier) or
  `:builtin` (no recon: exberly is built without it).
  """
  def recon_status(node) do
    cond do
      loaded_by_us?(node) -> :loaded
      node_has_recon?(node) -> :node
      local_recon?() and load_recon(node) == :ok -> :loaded
      true -> :builtin
    end
  end

  defp loaded_by_us?(node) do
    match?({:ok, true}, Target.rpc(node, :persistent_term, :get, [{:exberly, :recon}, false]))
  end

  defp node_has_recon?(node),
    do: match?({:ok, {:module, :recon}}, Target.rpc(node, :code, :ensure_loaded, [:recon]))

  defp local_recon?, do: match?({:module, :recon}, Code.ensure_loaded(:recon))

  defp load_recon(node) do
    result =
      Enum.reduce_while(@recon_modules, :ok, fn mod, :ok ->
        case AgentLoader.ensure_loaded(node, &Target.rpc/4, mod) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)

    if result == :ok,
      do: Target.rpc(node, :persistent_term, :put, [{:exberly, :recon}, true])

    result
  end

  @doc "`erlang:memory()` with counts and limits (see `exberly_agent:memory_snapshot/0`)."
  def snapshot(node), do: call(node, :memory_snapshot, [])

  @doc "Top `n` processes by `attr` (`:memory`, `:message_queue_len`, `:binary_memory`, ...)."
  def top_processes(node, attr, n), do: call(node, :top_processes, [attr, n])

  @doc "Garbage collects every process: memory before and after."
  def gc_all(node), do: call(node, :gc_all, [])

  @doc "Collects every process and reports who released the most binaries (recon:bin_leak/1)."
  def binary_leaks(node, n), do: call(node, :binary_leaks, [n])

  def ets_tables(node), do: call(node, :ets_tables, [])

  @doc "A process's stack (and with `status?`, `sys:get_status/2`)."
  def process_state(node, pid, status?), do: call(node, :process_state, [pid, status?])

  defp call(node, fun, args), do: Target.rpc(node, :exberly_agent, fun, args, @timeout)
end
