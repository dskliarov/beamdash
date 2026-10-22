defmodule Beamdash.CallGraph do
  @moduledoc """
  Static call graphs from xref, through erlyberly.

  `index/2` builds an xref index of the target's code paths (OTP and Elixir
  standard libraries excluded); that can take a while on big systems, so it
  is built once and reused. `analyse/5` then returns what a function calls,
  as a tree of `%{mfa: {m, f, a}, calls: [tree] | :more}`. `:more` marks a
  branch cut off by the depth limit. Calls into excluded code are leaves.
  """

  alias Beamdash.Target

  @index_timeout 300_000

  @doc "Builds the xref index unless one already exists (`force: true` rebuilds it)."
  def index(node, opts \\ []) do
    running? = match?({:ok, pid} when is_pid(pid), whereis_xref(node))

    if running? and not Keyword.get(opts, :force, false) do
      :ok
    else
      case :erpc.call(node, :erlyberly, :ensure_xref_started, [], @index_timeout) do
        {:ok, :erlyberly_xref_started} -> :ok
        other -> {:error, other}
      end
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp whereis_xref(node), do: Target.rpc(node, :erlang, :whereis, [:erlyberly_xref])

  @doc "The call tree of `mod:fun/arity`, `max_depth` levels deep."
  def analyse(node, mod, fun, arity, opts \\ []) do
    ignore = Keyword.get(opts, :ignore, [])
    depth = Keyword.get(opts, :max_depth, 6)

    with :ok <- index(node),
         {:ok, {:ok, tree}} <-
           Target.rpc(node, :erlyberly, :xref_analysis, [ignore, mod, fun, arity, depth]) do
      {:ok, to_tree(tree)}
    else
      {:ok, other} -> {:error, other}
      {:error, _} = error -> error
    end
  end

  defp to_tree({mfa, :more}), do: %{mfa: mfa, calls: :more}
  defp to_tree({mfa, calls}), do: %{mfa: mfa, calls: Enum.map(calls, &to_tree/1)}

  @doc "Number of functions in a tree (for the UI summary)."
  def size(%{calls: :more}), do: 1
  def size(%{calls: calls}), do: 1 + Enum.sum(Enum.map(calls, &size/1))
end
