defmodule Beamdash.OtpProcess do
  @moduledoc """
  Looking inside OTP processes on the connected node: the state of a
  gen_server or gen_statem (`sys:get_state/2`) and the supervision tree
  under a supervisor (`supervisor:which_children/1`, recursively), through
  `beamdash_agent`.
  """

  alias Beamdash.{Record, Target}

  @timeout 30_000

  @doc """
  `{:ok, %{module, state, at}}` with records named after the callback
  module's record definitions (when it has debug info), or
  `{:error, :timeout | :noproc | reason}`.
  """
  def state(pid) do
    with %{status: :connected, node: node} <- Target.status(),
         {:ok, {:ok, mod, state, defs}} <-
           Target.rpc(node, :beamdash_agent, :get_state, [pid], @timeout) do
      {:ok, %{module: mod, state: Record.name_records(state, defs), at: DateTime.utc_now()}}
    else
      %{status: _} -> {:error, :not_connected}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  `{:ok, tree}`: nested maps with `:pid` (or `:restarting` / `:undefined`
  for a child that is not running), `:id`, `:type` (`:supervisor` |
  `:worker`), `:name`, `:kind`, `:modules`, `:memory`, `:message_queue_len`,
  `:strategy` (supervisors) and `:children` (a list, `:more` past the depth
  limit, or `{:error, reason}`).
  """
  def tree(pid) do
    with %{status: :connected, node: node} <- Target.status(),
         {:ok, tree} <- Target.rpc(node, :beamdash_agent, :supervision_tree, [pid], @timeout) do
      {:ok, Map.put(tree, :at, DateTime.utc_now())}
    else
      %{status: _} -> {:error, :not_connected}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Counts of a tree: `%{supervisors: n, workers: n, not_running: n}`."
  def counts(tree), do: count(tree, %{supervisors: 0, workers: 0, not_running: 0})

  defp count(%{pid: pid} = node, acc) when not is_pid(pid) do
    acc = Map.update!(acc, :not_running, &(&1 + 1))
    children(node) |> Enum.reduce(acc, &count/2)
  end

  defp count(%{type: :supervisor} = node, acc),
    do: children(node) |> Enum.reduce(Map.update!(acc, :supervisors, &(&1 + 1)), &count/2)

  defp count(node, acc),
    do: children(node) |> Enum.reduce(Map.update!(acc, :workers, &(&1 + 1)), &count/2)

  defp children(%{children: list}) when is_list(list), do: list
  defp children(_), do: []
end
