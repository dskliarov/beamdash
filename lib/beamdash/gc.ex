defmodule Beamdash.GC do
  @moduledoc "Process-local GC samples and bounded, opt-in GC tracing on the target."
  alias Beamdash.Target

  def snapshot(node), do: Target.rpc(node, :beamdash_agent, :gc_snapshot, [])

  def trace(node, pid, owner, seconds \\ 10),
    do: Target.rpc(node, :beamdash_agent, :gc_trace_start, [pid, owner, seconds])

  def stop(collector) when is_pid(collector), do: send(collector, :stop)
  def stop(_), do: :ok

  @doc "Node-wide rates. Process minor_gcs is deliberately never treated as cumulative."
  def rates(nil, _), do: nil

  def rates(previous, current) do
    elapsed = current.sampled_at_ms - previous.sampled_at_ms

    if elapsed > 0 and current.collections >= previous.collections and
         current.reclaimed_bytes >= previous.reclaimed_bytes do
      %{
        collections: (current.collections - previous.collections) * 1000 / elapsed,
        reclaimed: round((current.reclaimed_bytes - previous.reclaimed_bytes) * 1000 / elapsed)
      }
    end
  end
end
