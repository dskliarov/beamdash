defmodule Beamdash.GCAdvisor do
  @moduledoc """
  "What to investigate next" about one process's garbage collection, from
  Jev. Like `Beamdash.ProcessAdvisor`, beamdash sends derived facts (heap
  and binary trends, shares, a GC trace summary with rates and pause
  times, rank on the node) and asks only once enough samples exist.
  """
  alias Beamdash.Jev
  alias Beamdash.Jev.Features, as: F

  @min_samples 15
  @min_window_ms 14_000

  @memory [:total, :heap, :total_heap, :stack, :binary_count, :binary_bytes]
  @gc [
    :minor_gcs,
    :fullsweep_after,
    :min_heap_size,
    :min_bin_vheap_size,
    :heap_block_size,
    :old_heap_size,
    :old_heap_block_size,
    :mbuf_size,
    :recent_size,
    :bin_vheap_size,
    :bin_old_vheap_size
  ]

  @choices %{
    "inspect_binaries" => %{
      label: "Inspect retained binaries",
      what:
        "Referenced binaries are a large or growing part of memory: compare before and after a forced GC; a live sub-binary keeps its whole parent.",
      not_for: "Heap-dominated memory with few binary bytes."
    },
    "inspect_mailbox" => %{
      label: "Investigate message backlog",
      what:
        "The queue is long or growing: queued messages are heap data, so the backlog, not GC, drives memory.",
      not_for: "An empty or draining queue."
    },
    "inspect_allocations" => %{
      label: "Profile allocation",
      what:
        "Frequent collections or a high share of time in GC, or old heap filling quickly: find what allocates (tprof memory mode on the Profile tab) before tuning heap settings.",
      not_for: "Rare, short collections."
    },
    "review_hibernation" => %{
      label: "Review idle process memory",
      what:
        "Idle, no collections, yet holding notable heap high on the node: application-level hibernation can compact it.",
      not_for: "Busy processes or small heaps."
    },
    "record_gc_trace" => %{
      label: "Record a GC trace during real work",
      what:
        "No trace yet, or the trace saw no collections: frequency and pause time are unknown, and the heap figures alone point nowhere else.",
      not_for: "A trace with collections already recorded under load."
    },
    "no_clear_issue" => %{
      label: "No clear issue",
      what:
        "Stable heap, modest binaries, collections short and infrequent: nothing in GC needs attention in this window.",
      not_for: "Clear growth, backlog or heavy collection work."
    }
  }

  @question %{
    question:
      "Which garbage-collection investigation should come next for this Erlang/Elixir process?",
    rules: [
      "Suggest an investigation, not a diagnosis or a runtime change.",
      "minor_gcs_since_full_sweep resets at every full sweep; it is not a rate.",
      "Collections forced by the user during the trace are not evidence of spontaneous sweeps.",
      "Binary bytes may be shared with other processes.",
      "Null means not measured."
    ]
  }

  def choices, do: @choices

  @doc "API key present (the shared Jev configuration)."
  def configured?, do: Jev.configured?()

  # Never serialize the whole process map: it holds stacks, links and messages.
  @doc "One numeric sample of a process_details/2 result."
  def sample(detail) do
    %{
      memory_bytes: numeric(detail.memory, @memory),
      gc: numeric(detail.gc, @gc),
      queued_messages: detail.mailbox.length
    }
  end

  @doc "`{:ready, seconds}` or `{:collecting, seconds, needed}` for samples with `offset_ms`."
  def readiness(samples) do
    ms =
      case samples do
        [%{offset_ms: first} | _] -> List.last(samples).offset_ms - first
        _ -> 0
      end

    if length(samples) >= @min_samples and ms >= @min_window_ms,
      do: {:ready, div(ms, 1000)},
      else: {:collecting, div(ms, 1000), div(@min_window_ms, 1000) + 1}
  end

  def analyze(evidence, opts \\ []) do
    with {:ok, answer} <- Jev.ask(evidence, @question, @choices, opts) do
      c = @choices[answer.choice]

      {:ok,
       Map.merge(answer, %{
         title: c.label,
         description: c.what,
         samples: evidence[:observed_samples],
         window_s: evidence[:observed_window_s],
         at: DateTime.utc_now()
       })}
    end
  end

  @doc """
  The state sent to Jev: `samples` (from `sample/1`, with `offset_ms`),
  GC trace `events`, how long the trace ran, collections the user forced
  meanwhile, the last Force GC result and node `context`.
  """
  def evidence(detail, samples, events, trace_ms, forced_count, forced_gc, context \\ %{}) do
    samples = Enum.take(samples, -60)
    pts = fn f -> Enum.map(samples, &{&1.offset_ms / 1000, f.(&1)}) end
    totals = Enum.map(samples, & &1.memory_bytes.total)
    mem = detail.memory
    gc = detail.gc
    durations = Enum.map(events, & &1.duration_us)
    total_us = Enum.sum(durations)

    %{
      observed_samples: length(samples),
      observed_window_s: window(samples),
      node: context,
      heap: %{
        process_memory_bytes: mem.total,
        memory_change_over_window_pct: F.change_pct(totals),
        memory_growth_bytes_per_s: F.slope(pts.(& &1.memory_bytes.total)),
        old_heap_bytes: gc[:old_heap_size],
        old_heap_growth_bytes_per_s: F.slope(pts.(& &1.gc.old_heap_size)),
        old_heap_share_of_heap_pct: F.share(gc[:old_heap_size], mem[:total_heap]),
        live_after_last_gc_bytes: gc[:recent_size],
        heap_fragments_bytes: gc[:mbuf_size],
        min_heap_bytes: gc[:min_heap_size],
        minor_gcs_since_full_sweep: gc[:minor_gcs],
        fullsweep_after: gc[:fullsweep_after]
      },
      binaries: %{
        bytes: mem[:binary_bytes],
        count: mem[:binary_count],
        bytes_per_process_memory_byte: F.ratio(mem[:binary_bytes], mem.total),
        growth_bytes_per_s: F.slope(pts.(& &1.memory_bytes.binary_bytes))
      },
      mailbox: %{
        queued_now: detail.mailbox.length,
        queue_growth_per_s: F.slope(pts.(& &1.queued_messages))
      },
      gc_trace:
        if trace_ms > 0 do
          %{
            observed_s: Float.round(trace_ms / 1000, 1),
            collections: length(events),
            minor: Enum.count(events, &(&1.kind == :minor)),
            full_sweeps: Enum.count(events, &(&1.kind == :major)),
            collections_per_s: Float.round(length(events) / max(trace_ms / 1000, 0.001), 2),
            mean_pause_us: F.mean(durations),
            max_pause_us: F.max_of(durations),
            share_of_time_in_gc_pct: F.share(total_us, trace_ms * 1000),
            mean_reclaimed_bytes:
              F.mean(Enum.map(events, &((&1[:before] || 0) - (&1[:after] || 0)))),
            forced_by_user: forced_count
          }
        end,
      last_forced_gc:
        if is_map(forced_gc) do
          %{
            before_bytes: forced_gc.before,
            after_bytes: forced_gc.after,
            freed_pct: F.share(forced_gc.before - forced_gc.after, forced_gc.before)
          }
        end
    }
  end

  defp window([]), do: 0
  defp window([first | _] = s), do: div(List.last(s).offset_ms - first.offset_ms, 1000)

  defp numeric(map, keys),
    do:
      Map.new(keys, fn key ->
        value = Map.get(map, key)
        {key, if(is_number(value), do: value, else: nil)}
      end)
end
