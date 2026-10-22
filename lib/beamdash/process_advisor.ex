defmodule Beamdash.ProcessAdvisor do
  @moduledoc """
  "What to investigate next" for one process, from Jev.

  beamdash does the arithmetic: the state sent is derived facts (queue
  growth per second, memory change, reductions rate, shares, rank on the
  node, a wait category) plus a short raw series as backup. It asks only
  once enough history is collected (`readiness/1`), so "collect more
  evidence" is decided here, not guessed by the model.
  """
  alias Beamdash.Jev
  alias Beamdash.Jev.Features, as: F

  @min_samples 15
  @min_window_s 14

  @choices %{
    "inspect_mailbox" => %{
      label: "Investigate message backlog",
      what:
        "Messages arrive faster than they are handled: the queue is growing or stays long. Find the producers and what slows handling.",
      not_for: "A short queue that drains between samples."
    },
    "profile_cpu" => %{
      label: "Profile CPU work",
      what:
        "Sustained high reductions per second, high on the node, while the queue does not grow: the process is busy doing work. Profile which functions.",
      not_for: "Occasional bursts, or an idle process."
    },
    "inspect_heap_growth" => %{
      label: "Investigate heap growth",
      what:
        "Process memory keeps rising across the window and stays high after collections: data retained in state or on the heap.",
      not_for: "Memory mostly in binaries; or a stable size."
    },
    "inspect_binaries" => %{
      label: "Inspect retained binaries",
      what:
        "Referenced binary bytes are large compared with the heap, or growing: the process may keep binaries (or sub-binaries of large ones) alive.",
      not_for: "Small binary totals; heap-dominated memory."
    },
    "inspect_gc" => %{
      label: "Record GC activity",
      what:
        "Many collections or old-heap pressure suggest collection work matters: trace GC on the GC page to measure it.",
      not_for: "Memory growth with no sign of collection pressure."
    },
    "inspect_blocking" => %{
      label: "Inspect what it waits on",
      what:
        "Waiting in application code, in a call for another process's reply (call_reply), on I/O or suspended while its queue grows or callers would be waiting: it may be blocked on another process or resource.",
      not_for: "Idle in an OTP receive loop with an empty queue: that is normal."
    },
    "review_idle_memory" => %{
      label: "Review idle process memory",
      what:
        "Idle (no work, empty queue) yet holding notable memory, high on the node: consider hibernation in the application.",
      not_for: "Busy processes, or small ones."
    },
    "no_clear_issue" => %{
      label: "No clear issue",
      what:
        "The measurements look normal: stable memory, queue drained, work proportionate. Nothing points to a problem in this window.",
      not_for: "Any clear growth, backlog or sustained load."
    }
  }

  @question %{
    question:
      "Which investigation should come next for this Erlang/Elixir process, given these measurements?",
    rules: [
      "Suggest an investigation, not a diagnosis.",
      "Growth figures are per second over observed_window_s; shares and ranks are percentages.",
      "Reductions are units of work, not CPU time.",
      "Binary bytes may be shared with other processes.",
      "Waiting in an OTP receive loop with an empty queue is normal idleness.",
      "Null means not measured."
    ]
  }

  def choices, do: @choices
  def min_samples, do: @min_samples

  @doc """
  `{:ready, seconds}` once enough history is collected, else
  `{:collecting, seconds, needed}`.
  """
  def readiness(history) do
    seconds =
      case history do
        [%{at_us: first} | _] -> div(List.last(history).at_us - first, 1_000_000)
        _ -> 0
      end

    if length(history) >= @min_samples and seconds >= @min_window_s,
      do: {:ready, seconds},
      else: {:collecting, seconds, @min_window_s + 1}
  end

  def analyze(evidence, opts \\ []) do
    with {:ok, answer} <- Jev.ask(evidence, @question, @choices, opts),
         do: {:ok, advice(answer, evidence)}
  end

  @doc "Advice for the UI from a parsed Jev answer."
  def advice(answer, evidence) do
    c = @choices[answer.choice]

    Map.merge(answer, %{
      title: c.label,
      description: c.what,
      samples: evidence[:observed_samples],
      window_s: evidence[:observed_window_s],
      at: DateTime.utc_now()
    })
  end

  @doc """
  The state sent to Jev for `detail` (process_details/2), its `history`
  (ProcessStats points, oldest first) and `context` (`Features.node_context/2`).
  """
  def evidence(detail, history, context \\ %{}) do
    points = Enum.take(history, -60)
    t0 = with [%{at_us: at} | _] <- points, do: at, else: (_ -> 0)
    t = fn p -> (p.at_us - t0) / 1_000_000 end
    series = fn key -> Enum.map(points, &Map.get(&1, key)) end
    queue = series.(:message_queue_len)
    memory = series.(:memory)
    rates = series.(:reds_per_sec)
    mem = detail.memory

    %{
      observed_samples: length(points),
      observed_window_s: window(points),
      process: %{
        status: detail.status,
        waiting_in: F.wait_category(detail.status, detail[:current_function]),
        traps_exits: detail[:trap_exit] == true,
        priority: detail[:priority],
        messages_stored: mem[:message_queue_data],
        link_count: length(detail[:links] || []),
        monitor_count: length(detail[:monitors] || []),
        monitored_by_count: length(detail[:monitored_by] || [])
      },
      node: context,
      mailbox: %{
        queued_now: detail.mailbox.length,
        queued_max: F.max_of(queue),
        queue_growth_per_s: F.slope(Enum.map(points, &{t.(&1), &1.message_queue_len}))
      },
      work: %{
        reductions_per_s_mean: F.mean(rates),
        reductions_per_s_max: F.max_of(rates),
        reductions_per_s_now: List.last(rates)
      },
      memory: %{
        bytes_now: mem.total,
        change_over_window_pct: F.change_pct(memory),
        growth_bytes_per_s: F.slope(Enum.map(points, &{t.(&1), &1.memory})),
        binary_bytes: mem[:binary_bytes],
        binary_count: mem[:binary_count],
        binary_bytes_per_process_memory_byte: F.ratio(mem[:binary_bytes], mem.total),
        old_heap_share_of_heap_pct: F.share(detail.gc[:old_heap_size], mem[:total_heap]),
        minor_gcs_since_full_sweep: detail.gc[:minor_gcs],
        fullsweep_after: detail.gc[:fullsweep_after]
      },
      raw_series:
        points
        |> F.thin(10)
        |> Enum.map(fn p ->
          %{
            at_s: Float.round(t.(p), 1),
            queued: p.message_queue_len,
            memory_bytes: p.memory,
            reductions_per_s: p.reds_per_sec
          }
        end)
    }
  end

  defp window([]), do: 0
  defp window([first | _] = points), do: div(List.last(points).at_us - first.at_us, 1_000_000)
end
