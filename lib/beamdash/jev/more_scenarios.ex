defmodule Beamdash.Jev.MoreScenarios do
  @moduledoc """
  Scenarios with a known right answer for the node-memory check
  (`:memory`), the seq-trace pattern (`:seq`), "Ask beamdash" (`:route`,
  the evidence is the typed question) and the table triage (`:triage`,
  the evidence is the request and the expected answer is the set of
  processes that should be flagged). Run by `mix beamdash.jev_eval`.
  """
  alias Beamdash.{MemoryAdvisor, SeqAdvisor, TriageAdvisor}

  @seconds 30
  @mb 1_048_576

  def all, do: memory() ++ seq() ++ route() ++ [triage()]

  ## Node memory

  def memory do
    [
      mem("binary leak", ["binary"], binary: &(50 * @mb + &1 * 6 * @mb)),
      mem("ETS growth", ["ets"], ets: &(20 * @mb + &1 * 4 * @mb)),
      mem("atom leak", ["atoms"],
        atom: &(30 * @mb + &1 * @mb),
        atom_count: &(850_000 + &1 * 4_000)
      ),
      mem("process heaps growing", ["processes"], processes: &(200 * @mb + &1 * 9 * @mb)),
      mem("allocator fragmentation", ["allocators"], alloc: {3_000 * @mb, 900 * @mb}),
      mem("healthy node", ["no_clear_issue"], [])
    ]
  end

  defp mem(name, expect, o) do
    o = Map.new(o)
    at = fn key, default, s -> if f = o[key], do: f.(s), else: default end

    snap_at = fn s ->
      processes = at.(:processes, 180 * @mb, s)
      binary = at.(:binary, 40 * @mb, s)
      ets = at.(:ets, 15 * @mb, s)
      atom = at.(:atom, 2 * @mb, s)
      code = 40 * @mb
      other = 60 * @mb
      system = binary + ets + atom + code + other

      %{
        memory: %{
          total: processes + system,
          processes: processes,
          processes_used: processes,
          system: system,
          atom: atom,
          atom_used: atom,
          binary: binary,
          code: code,
          ets: ets
        },
        atom_count: at.(:atom_count, 30_000, s),
        atom_limit: 1_048_576,
        process_count: 2_000,
        process_limit: 262_144,
        ets_count: 120,
        ets_limit: 8_192,
        module_count: 900,
        alloc:
          case o[:alloc] do
            {allocated, used} ->
              %{allocated: allocated, used: used, usage: used / allocated}

            nil ->
              %{
                allocated: round((processes + system) * 1.15),
                used: processes + system,
                usage: 0.87
              }
          end
      }
    end

    history = for s <- 0..@seconds//2, do: %{at: s * 1000, memory: snap_at.(s).memory}

    %{
      advisor: :memory,
      name: name,
      expect: expect,
      evidence: MemoryAdvisor.evidence(snap_at.(@seconds), history)
    }
  end

  ## Seq trace

  def seq do
    [
      flow("request storm", ["request_storm", "slow_responder"], storm()),
      flow("fan-out", ["fan_out"], fan_out()),
      flow("chatty exchange", ["chatty_exchange"], chatty()),
      flow("deep chain", ["deep_chain"], chain()),
      flow("slow responder", ["slow_responder"], slow()),
      flow("normal flow", ["normal_flow"], normal())
    ]
  end

  defp flow(name, expect, events),
    do: %{advisor: :seq, name: name, expect: expect, evidence: SeqAdvisor.evidence(events)}

  defp pid(i), do: "<0.#{100 + i}.0>"

  defp msg(from, to, msg, t, serial),
    do: %{type: :send, from: from, to: to, message: msg, timestamp_us: t, serial: serial}

  defp call(from, to, t, prev, cur, reply_after) do
    ref = make_ref()

    [
      msg(from, to, {:"$gen_call", {self(), [:alias | ref]}, :req}, t, {prev, cur}),
      msg(to, from, {[:alias | ref], :ok}, t + reply_after, {cur, cur + 1})
    ]
  end

  defp storm do
    for i <- 1..40, reduce: [] do
      acc -> acc ++ call(pid(i), pid(0), i * 2_000, 0, i * 10, 40_000 + i * 3_000)
    end
  end

  defp fan_out do
    for i <- 1..30, do: msg(pid(0), pid(i), {:"$gen_cast", {:update, i}}, i * 500, {1, 1 + i})
  end

  defp chatty do
    for i <- 1..40,
        do:
          if(rem(i, 2) == 0,
            do: msg(pid(1), pid(2), {:chunk, i}, i * 1_000, {i, i + 1}),
            else: msg(pid(2), pid(1), {:ack, i}, i * 1_000, {i, i + 1})
          )
  end

  defp chain do
    for c <- 0..2, hop <- 0..7 do
      base = c * 100

      msg(
        pid(c * 10 + hop),
        pid(c * 10 + hop + 1),
        {:forward, c},
        c * 50_000 + hop * 2_000,
        {base + hop, base + hop + 1}
      )
    end
  end

  defp slow do
    answered =
      for i <- 1..6, reduce: [] do
        acc -> acc ++ call(pid(i), pid(0), i * 100_000, 0, i * 10, 900_000)
      end

    unanswered =
      for i <- 7..9 do
        ref = make_ref()

        msg(
          pid(i),
          pid(0),
          {:"$gen_call", {self(), [:alias | ref]}, :req},
          i * 100_000,
          {0, i * 10}
        )
      end

    answered ++ unanswered
  end

  defp normal do
    for i <- 1..6, reduce: [] do
      acc -> acc ++ call(pid(i), pid(0), i * 300_000, 0, i * 10, 400)
    end
  end

  ## Ask beamdash

  def route do
    [
      {"who is leaking binaries?", ["memory_binaries"]},
      {"which processes use the most memory", ["processes_by_memory"]},
      {"some mailbox keeps growing", ["processes_by_queue"]},
      {"what is eating the CPU right now", ["processes_by_cpu"]},
      {"show me the supervisors", ["supervisors"]},
      {"do we have a memory leak?", ["memory_health"]},
      {"an ETS table keeps getting bigger", ["memory_ets"]},
      {"trace calls to demo_shop", ["trace"]},
      {"where does checkout spend its time", ["profile"]},
      {"why did my process crash", ["crashes"]},
      {"follow the messages between my gen_servers", ["seq_trace"]},
      {"GC pauses are long", ["gc"]},
      {"the node feels slow, where should I start", ["process_triage"]},
      {"what's the weather in Paris", ["none"]}
    ]
    |> Enum.map(fn {q, expect} -> %{advisor: :route, name: q, expect: expect, evidence: q} end)
  end

  ## Triage

  @doc """
  A table of 12 processes, 30 s of history: six with a problem (backlog,
  hot loop, heap growth, idle memory hog, blocked with a growing queue,
  a second backlog) and six healthy idle servers. The expected answer is
  the ids of the six.
  """
  def triage do
    specs =
      [
        {:backlog, true,
         fn s -> {300_000 + s * 50_000, s * 120, 30_000, :waiting, {:gen_server, :loop, 7}} end},
        {:hot, true, fn _ -> {80_000, 0, 600_000, :running, {:lists, :foldl, 3}} end},
        {:heap, true,
         fn s -> {1_000_000 + s * 1_500_000, 0, 3_000, :waiting, {:gen_server, :loop, 7}} end},
        {:hog, true, fn _ -> {60_000_000, 0, 0, :waiting, {:gen_server, :loop, 7}} end},
        {:blocked, true,
         fn s -> {90_000 + s * 800, div(s * 7, 2), 0, :waiting, {:my_client, :await, 2}} end},
        {:backlog2, true,
         fn s -> {200_000 + s * 30_000, s * 60, 20_000, :waiting, {:gen_server, :loop, 7}} end}
      ] ++
        for i <- 1..6 do
          {:"idle#{i}", false,
           fn s ->
             {20_000 + i * 1_000, 0, if(rem(s, 10) == 0, do: 200, else: 0), :waiting,
              {:gen_server, :loop, 7}}
           end}
        end

    # pids (and so ids) interleave problem and healthy processes
    order = [3, 8, 1, 11, 6, 10, 2, 12, 5, 9, 4, 7]

    pids =
      Map.new(Enum.zip(specs, order), fn {{name, _, _}, i} -> {name, :c.pid(0, 700 + i, 0)} end)

    procs_at = fn s ->
      for {name, _bad, f} <- specs do
        {memory, queue, _rate, status, current} = f.(s)

        %{
          pid: pids[name],
          registered_name: nil,
          memory: memory,
          message_queue_len: queue,
          reductions: s * 1000,
          status: status,
          current_function: current,
          kind: :gen_server
        }
      end
    end

    rates_at = fn s -> Map.new(specs, fn {name, _, f} -> {pids[name], elem(f.(s), 2)} end) end

    history =
      Enum.reduce(0..@seconds//2, nil, fn s, h ->
        TriageAdvisor.track(h, procs_at.(s), rates_at.(s), s * 1_000_000)
      end)

    {state, questions, ids} =
      req = TriageAdvisor.request(procs_at.(@seconds), rates_at.(@seconds), history)

    bad = for {name, true, _} <- specs, do: pids[name]

    %{
      advisor: :triage,
      name: "table of 12 processes, 6 with a problem",
      expect: for({id, pid} <- ids, pid in bad, do: id) |> Enum.sort(),
      evidence: req,
      state: state,
      questions: questions
    }
  end
end
