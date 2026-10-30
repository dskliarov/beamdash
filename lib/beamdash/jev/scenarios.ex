defmodule Beamdash.Jev.Scenarios do
  @moduledoc """
  A fixed set of synthetic processes with a known right answer, to measure
  Jev's suggestions (`mix beamdash.jev_eval`) and to re-check before
  changing `TYPESAFE_MODEL`. Each scenario builds its state with the same
  code as the real panels, from made-up process details and history.
  """
  alias Beamdash.{GCAdvisor, ProcessAdvisor}
  alias Beamdash.Jev.Features

  @seconds 30

  @doc "`[%{advisor: :process | :gc, name, expect: [choice], evidence}]`"
  def all, do: process() ++ gc()

  def process do
    [
      p("message backlog", ["inspect_mailbox"],
        queue: &(&1 * 100),
        reds: fn _ -> 40_000 end,
        mem: &(200_000 + &1 * 40_000),
        current: {:gen_server, :loop, 7}
      ),
      p("hot loop", ["profile_cpu"],
        status: :running,
        reds: fn _ -> 450_000 end,
        mem: fn _ -> 60_000 end,
        current: {:lists, :foldl, 3},
        rate_rank: 0.5
      ),
      p("heap growth", ["inspect_heap_growth"],
        reds: fn _ -> 2_000 end,
        mem: &(1_000_000 + &1 * 1_300_000),
        current: {:gen_server, :loop, 7},
        old_heap: 30_000_000,
        mem_rank: 0.5
      ),
      p("binary retention", ["inspect_binaries"],
        reds: fn _ -> 1_000 end,
        mem: fn _ -> 90_000 end,
        binaries: 250_000_000,
        current: {:gen_server, :loop, 7}
      ),
      p("idle memory hog", ["review_idle_memory"],
        reds: fn _ -> 0 end,
        mem: fn _ -> 48_000_000 end,
        current: {:gen_server, :loop, 7},
        old_heap: 40_000_000,
        mem_rank: 0.3
      ),
      p("blocked in application code", ["inspect_blocking", "inspect_mailbox"],
        reds: fn _ -> 0 end,
        queue: &div(&1 * 7, 2),
        mem: &(80_000 + &1 * 600),
        current: {:my_app_client, :await_reply, 2}
      ),
      p("blocked in a call to another process", ["inspect_blocking", "inspect_mailbox"],
        reds: fn _ -> 0 end,
        queue: &div(&1 * 5, 2),
        mem: &(60_000 + &1 * 400),
        current: {:gen, :do_call, 4}
      ),
      p("healthy idle server", ["no_clear_issue"],
        reds: fn s -> if rem(s, 10) == 0, do: 300, else: 0 end,
        mem: fn _ -> 21_000 end,
        current: {:gen_server, :loop, 7}
      )
    ]
  end

  def gc do
    [
      g("binary heavy", ["inspect_binaries"],
        binaries: 180_000_000,
        mem: fn _ -> 120_000 end
      ),
      g("allocation churn", ["inspect_allocations"],
        mem: fn s -> 2_000_000 + rem(s, 5) * 400_000 end,
        trace: {5_000, 220, 0.08}
      ),
      g("idle big heap", ["review_hibernation"],
        mem: fn _ -> 52_000_000 end,
        old_heap: 45_000_000,
        trace: {10_000, 0, 0},
        mem_rank: 0.3
      ),
      g("growing mailbox", ["inspect_mailbox"],
        mem: &(300_000 + &1 * 90_000),
        queue: &(&1 * 250)
      ),
      g("not traced yet", ["record_gc_trace", "no_clear_issue"], mem: fn _ -> 400_000 end),
      g("healthy with trace", ["no_clear_issue"],
        mem: fn _ -> 40_000 end,
        trace: {10_000, 3, 0.02}
      )
    ]
  end

  @doc false
  # The builders, for the local model's training data
  # (`Beamdash.Insights.Training`): same options as the scenarios below.
  def process_case(name, expect, opts), do: p(name, expect, opts)

  @doc false
  def gc_case(name, expect, opts), do: g(name, expect, opts)

  ## Process scenarios

  defp p(name, expect, o) do
    o = Map.new(o)
    queue = Map.get(o, :queue, fn _ -> 0 end)
    t0 = 1_000_000_000

    history =
      for s <- 0..@seconds do
        %{
          at_us: t0 + s * 1_000_000,
          reductions: s * o.reds.(s),
          reds_per_sec: if(s == 0, do: nil, else: o.reds.(s)),
          memory: o.mem.(s),
          message_queue_len: queue.(s)
        }
      end

    last = List.last(history)
    detail = detail(o, last.memory, last.message_queue_len)

    rows =
      rows(
        last.memory,
        Map.get(o, :mem_rank, 40),
        last.message_queue_len,
        o.reds.(@seconds),
        Map.get(o, :rate_rank, 40)
      )

    %{
      advisor: :process,
      name: name,
      expect: expect,
      evidence: ProcessAdvisor.evidence(detail, history, Features.node_context(rows, detail.pid))
    }
  end

  ## GC scenarios

  defp g(name, expect, o) do
    o = Map.new(o)
    queue = Map.get(o, :queue, fn _ -> 0 end)
    detail0 = detail(o, o.mem.(@seconds), queue.(@seconds))

    samples =
      for s <- 0..@seconds do
        d = detail(o, o.mem.(s), queue.(s))
        Map.put(GCAdvisor.sample(d), :offset_ms, s * 1000)
      end

    {trace_ms, events} =
      case o[:trace] do
        nil ->
          {0, []}

        {ms, n, share} ->
          per = if n > 0, do: round(ms * 1000 * share / n), else: 0

          {ms,
           for(
             i <- 1..n//1,
             do: %{
               kind: if(rem(i, 20) == 0, do: :major, else: :minor),
               duration_us: per,
               before: 2_400_000,
               after: 1_900_000
             }
           )}
      end

    rows = rows(detail0.memory.total, Map.get(o, :mem_rank, 40), queue.(@seconds), nil, nil)

    %{
      advisor: :gc,
      name: name,
      expect: expect,
      evidence:
        GCAdvisor.evidence(
          detail0,
          samples,
          events,
          trace_ms,
          0,
          nil,
          Features.node_context(rows, detail0.pid)
        )
    }
  end

  ## Shared

  defp detail(o, memory, queued) do
    binaries = Map.get(o, :binaries, 0)
    old = min(Map.get(o, :old_heap, div(memory, 4)), memory)

    %{
      pid: self(),
      status: Map.get(o, :status, :waiting),
      current_function: Map.get(o, :current, {:gen_server, :loop, 7}),
      trap_exit: false,
      priority: :normal,
      links: [:a],
      monitors: [],
      monitored_by: [],
      mailbox: %{length: queued},
      memory: %{
        total: memory,
        heap: memory - old,
        total_heap: memory,
        stack: 100,
        binary_bytes: binaries,
        binary_count: if(binaries > 0, do: 1200, else: 0),
        message_queue_data: :on_heap
      },
      gc: %{
        minor_gcs: 12,
        fullsweep_after: 65_535,
        min_heap_size: 1_864,
        min_bin_vheap_size: 371_656,
        heap_block_size: memory - old,
        old_heap_size: old,
        old_heap_block_size: old,
        mbuf_size: 0,
        recent_size: div(memory, 2),
        bin_vheap_size: binaries,
        bin_old_vheap_size: 0
      }
    }
  end

  # A node of 400 processes: this one (self()) ranks in the top `rank` %.
  defp rows(memory, rank, queue, rate, rate_rank) do
    others = 399
    above = round(others * rank / 100)

    me = %{pid: self(), memory: memory, queue: queue, rate: rate, kind: :gen_server}

    rest =
      for i <- 1..others do
        bigger = i <= above

        %{
          pid: :c.pid(0, 900 + i, 0),
          memory: if(bigger, do: memory * 2, else: max(div(memory, 50), 1_000)),
          queue: 0,
          rate:
            if(rate && rate_rank,
              do: if(i <= round(others * rate_rank / 100), do: rate * 2, else: div(rate, 100)),
              else: nil
            ),
          kind: nil
        }
      end

    [me | rest]
  end
end
