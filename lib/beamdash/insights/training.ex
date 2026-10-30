defmodule Beamdash.Insights.Training do
  @moduledoc """
  Trains `Beamdash.Insights.Model` (`mix beamdash.nx_train`).

  There is no labelled data from real nodes, so the examples are made up,
  like `mix beamdash.jev_eval`'s scenarios and with the same builders
  (`Beamdash.Jev.Scenarios`, `Beamdash.Jev.MoreScenarios`, the advisors'
  own `evidence` functions): for each answer, a generator draws its
  magnitudes at random over wide ranges (rates, sizes, growth, current
  function, rank on the node…) and builds the state a real panel would.
  A model is a multinomial logistic regression
  (`Scholar.Linear.LogisticRegression`) on standardized `Model.vector/2`s.

  Generation is seeded, so training is reproducible. `evaluate/2` scores
  a model on fresh examples from another seed; the fixed eval scenarios
  are deliberately not used for training.
  """
  alias Beamdash.{SeqAdvisor, TriageAdvisor}
  alias Beamdash.Insights.Model
  alias Beamdash.Jev.{MoreScenarios, Scenarios}

  @kinds [:process, :gc, :memory, :seq, :triage]
  @mb 1_048_576

  def kinds, do: @kinds

  @doc """
  Trains every kind: `%{version, trained_at, kinds: %{kind => model}}`.
  Options: `:per_class` (examples per answer, default 120), `:seed`,
  `:iterations` (default 150), `:alpha` (L2, default 0.01) and
  `:progress`, a 1-arity fun given messages.
  """
  def train_all(opts \\ []) do
    progress = Keyword.get(opts, :progress, fn _ -> :ok end)

    kinds =
      Map.new(@kinds, fn kind ->
        progress.("#{kind}: generating")
        samples = generate(kind, Keyword.get(opts, :per_class, 120), Keyword.get(opts, :seed, 1))
        progress.("#{kind}: training on #{length(samples)} examples")
        {kind, fit(samples, opts)}
      end)

    %{version: "1", trained_at: DateTime.utc_now() |> DateTime.to_iso8601(), kinds: kinds}
  end

  @doc "Fits one model to `[{state, class}]`."
  def fit(samples, opts \\ []) do
    {states, labels} = Enum.unzip(samples)
    classes = labels |> Enum.uniq() |> Enum.sort()
    vocab = Model.vocabulary(states)
    x = states |> Enum.map(&Model.vector(&1, vocab)) |> Nx.tensor(type: :f32)
    mean = Nx.mean(x, axes: [0])
    sd = x |> Nx.standard_deviation(axes: [0]) |> Nx.max(1.0e-3)
    xs = x |> Nx.subtract(mean) |> Nx.divide(sd)
    index = classes |> Enum.with_index() |> Map.new()
    y = labels |> Enum.map(&index[&1]) |> Nx.tensor()

    lr =
      Scholar.Linear.LogisticRegression.fit(xs, y,
        num_classes: length(classes),
        max_iterations: Keyword.get(opts, :iterations, 150),
        alpha: Keyword.get(opts, :alpha, 0.01)
      )

    %{
      classes: classes,
      vocabulary: vocab,
      mean: Nx.to_flat_list(mean),
      sd: Nx.to_flat_list(sd),
      coefficients: Nx.to_list(lr.coefficients),
      bias: Nx.to_flat_list(lr.bias),
      examples: length(samples)
    }
  end

  @doc "The share of `samples` whose top class is right, and the misses by `{want, got}`."
  def evaluate(model, samples) do
    results =
      Enum.map(samples, fn {state, want} ->
        {got, _} = model |> Model.predict(state) |> Enum.max_by(&elem(&1, 1))
        {want, got}
      end)

    right = Enum.count(results, fn {w, g} -> w == g end)
    misses = results |> Enum.reject(fn {w, g} -> w == g end) |> Enum.frequencies()
    {right / max(length(results), 1), misses}
  end

  ## Generators

  @doc "`per_class` random examples of each answer for `kind`: `[{state, class}]`."
  def generate(kind, per_class, seed) do
    :rand.seed(:exsss, {seed, :erlang.phash2(kind), 7})

    case kind do
      :triage ->
        triage(per_class)

      _ ->
        for {class, gen} <- generators(kind), _ <- 1..per_class, do: {gen.(), class}
    end
  end

  defp generators(:process) do
    [
      {"inspect_mailbox", &process_mailbox/0},
      {"profile_cpu", &process_cpu/0},
      {"inspect_heap_growth", &process_heap/0},
      {"inspect_binaries", &process_binaries/0},
      {"review_idle_memory", &process_idle_memory/0},
      {"inspect_blocking", &process_blocking/0},
      {"no_clear_issue", &process_healthy/0}
    ]
  end

  defp generators(:gc) do
    [
      {"inspect_binaries", &gc_binaries/0},
      {"inspect_allocations", &gc_allocations/0},
      {"review_hibernation", &gc_hibernation/0},
      {"inspect_mailbox", &gc_mailbox/0},
      {"record_gc_trace", &gc_untraced/0},
      {"no_clear_issue", &gc_healthy/0}
    ]
  end

  defp generators(:memory) do
    for class <- ~w(binary ets atoms processes allocators no_clear_issue),
        do: {class, fn -> memory(class) end}
  end

  defp generators(:seq) do
    [
      {"request_storm", &storm/0},
      {"fan_out", &fan_out/0},
      {"chatty_exchange", &chatty/0},
      {"deep_chain", &chain/0},
      {"slow_responder", &slow/0},
      {"normal_flow", &normal/0}
    ]
  end

  ## Process

  @otp_loops [{:gen_server, :loop, 7}, {:gen_statem, :loop_receive, 3}, {:gen_server, :loop, 6}]

  defp process(opts), do: Scenarios.process_case("", [], opts).evidence

  defp process_mailbox do
    r = lu(3, 400)
    reds = lu(2_000, 300_000)
    {base, g} = {lu(30_000, 3_000_000), lu(500, 80_000)}

    process(
      queue: fn s -> round(s * r * jit(0.1)) end,
      reds: fn _ -> round(reds * jit(0.2)) end,
      mem: fn s -> round(base + s * g) end,
      current: pick(@otp_loops),
      status: pick([:waiting, :waiting, :runnable]),
      mem_rank: u(0.5, 40),
      rate_rank: u(0.5, 40)
    )
  end

  defp process_cpu do
    reds = lu(120_000, 3_000_000)
    mem = lu(10_000, 800_000)

    process(
      status: pick([:running, :runnable]),
      reds: fn _ -> round(reds * jit(0.15)) end,
      mem: fn _ -> round(mem * jit(0.05)) end,
      current:
        pick([{:lists, :foldl, 3}, {:my_app, :compute, 2}, {:ets, :select, 2}, {:maps, :fold, 3}]),
      rate_rank: u(0.1, 3),
      mem_rank: u(5, 60)
    )
  end

  defp process_heap do
    {base, g} = {lu(200_000, 5_000_000), lu(80_000, 3_000_000)}

    process(
      reds: fn _ -> round(lu(200, 50_000)) end,
      mem: fn s -> round((base + s * g) * jit(0.03)) end,
      current: pick(@otp_loops),
      old_heap: round(lu(3_000_000, 100_000_000)),
      mem_rank: u(0.1, 3)
    )
  end

  defp process_binaries do
    mem = lu(20_000, 800_000)

    process(
      reds: fn _ -> round(lu(50, 30_000)) end,
      mem: fn _ -> round(mem * jit(0.05)) end,
      binaries: round(lu(20_000_000, 1_500_000_000)),
      current: pick(@otp_loops),
      mem_rank: u(1, 50)
    )
  end

  defp process_idle_memory do
    mem = round(lu(8_000_000, 300_000_000))

    process(
      reds: fn s -> if rem(s, 15) == 0, do: round(lu(1, 200)), else: 0 end,
      mem: fn _ -> mem end,
      current: pick([{:erlang, :hibernate, 3} | @otp_loops]),
      old_heap: round(mem * u(0.6, 0.95)),
      mem_rank: u(0.1, 3)
    )
  end

  defp process_blocking do
    r = u(0.0, 8.0)
    {base, g} = {lu(30_000, 300_000), u(0, 2_000)}

    process(
      reds: fn _ -> 0 end,
      queue: fn s -> round(s * r) end,
      mem: fn s -> round(base + s * g) end,
      current:
        pick([
          {:my_app_client, :await_reply, 2},
          {:gen, :do_call, 4},
          {:my_app_db, :query, 3},
          {:gen, :wait_response, 2}
        ])
    )
  end

  defp process_healthy do
    every = Enum.random(2..15)
    burst = lu(10, 20_000)
    mem = lu(5_000, 3_000_000)

    process(
      reds: fn s -> if rem(s, every) == 0, do: round(burst), else: 0 end,
      mem: fn _ -> round(mem * jit(0.02)) end,
      queue: fn _ -> if :rand.uniform() < 0.1, do: Enum.random(1..2), else: 0 end,
      current: pick([{:erlang, :hibernate, 3} | @otp_loops]),
      mem_rank: u(5, 95),
      rate_rank: u(5, 95)
    )
  end

  ## GC

  defp gc(opts), do: Scenarios.gc_case("", [], opts).evidence

  defp maybe_trace(n_max, share_max) do
    if :rand.uniform() < 0.5,
      do: {10_000, Enum.random(0..n_max), u(0.0, share_max)},
      else: nil
  end

  defp gc_binaries do
    mem = lu(30_000, 1_000_000)

    gc(
      binaries: round(lu(20_000_000, 1_500_000_000)),
      mem: fn _ -> round(mem) end,
      trace: maybe_trace(20, 0.02)
    )
  end

  defp gc_allocations do
    {base, amp} = {lu(500_000, 5_000_000), u(0.1, 0.5)}

    gc(
      mem: fn s -> round(base * (1 + amp * rem(s, 5) / 5)) end,
      trace: {round(lu(3_000, 10_000)), round(lu(60, 800)), u(0.04, 0.25)}
    )
  end

  defp gc_hibernation do
    mem = round(lu(8_000_000, 300_000_000))

    gc(
      mem: fn _ -> mem end,
      old_heap: round(mem * u(0.6, 0.95)),
      trace: {10_000, Enum.random(0..2), 0.0},
      mem_rank: u(0.1, 3)
    )
  end

  defp gc_mailbox do
    {base, g, r} = {lu(100_000, 2_000_000), lu(20_000, 300_000), lu(20, 600)}

    gc(
      mem: fn s -> round(base + s * g) end,
      queue: fn s -> round(s * r) end,
      trace: maybe_trace(40, 0.03)
    )
  end

  defp gc_untraced do
    mem = lu(50_000, 8_000_000)
    gc(mem: fn _ -> round(mem * jit(0.02)) end)
  end

  defp gc_healthy do
    mem = lu(10_000, 2_000_000)

    gc(
      mem: fn _ -> round(mem * jit(0.02)) end,
      trace: {10_000, round(lu(1, 20)), u(0.001, 0.03)}
    )
  end

  ## Node memory

  defp memory(class) do
    base = %{
      processes: lu(50 * @mb, 800 * @mb),
      binary: lu(10 * @mb, 300 * @mb),
      ets: lu(5 * @mb, 200 * @mb),
      atom: lu(1 * @mb, 10 * @mb),
      atom_count: lu(10_000, 300_000)
    }

    flat = fn key -> fn _ -> round(base[key] * jit(0.005)) end end
    grow = fn key, lo, hi -> fn s -> round(base[key] * (1 + s * u(lo, hi))) end end
    opts = for key <- [:processes, :binary, :ets, :atom, :atom_count], do: {key, flat.(key)}

    opts =
      case class do
        "binary" ->
          Keyword.put(opts, :binary, grow.(:binary, 0.02, 0.3))

        "ets" ->
          Keyword.put(opts, :ets, grow.(:ets, 0.02, 0.3))

        "processes" ->
          Keyword.put(opts, :processes, grow.(:processes, 0.01, 0.1))

        "atoms" ->
          {c0, g} = {lu(300_000, 950_000), lu(1_000, 10_000)}

          opts
          |> Keyword.put(:atom, grow.(:atom, 0.005, 0.05))
          |> Keyword.put(:atom_count, fn s -> min(round(c0 + s * g), 1_048_000) end)

        "allocators" ->
          allocated = lu(1_000 * @mb, 5_000 * @mb)
          Keyword.put(opts, :alloc, {round(allocated), round(allocated * u(0.15, 0.5))})

        "no_clear_issue" ->
          opts
      end

    MoreScenarios.memory_case("", [], opts).evidence
  end

  ## Seq trace

  defp pid(i), do: "<0.#{100 + i}.0>"

  defp msg(from, to, msg, t, serial),
    do: %{type: :send, from: from, to: to, message: msg, timestamp_us: round(t), serial: serial}

  defp call(from, to, t, prev, cur, reply_after) do
    ref = make_ref()

    [
      msg(from, to, {:"$gen_call", {self(), [:alias | ref]}, :req}, t, {prev, cur}),
      msg(to, from, {[:alias | ref], :ok}, t + reply_after, {cur, cur + 1})
    ]
  end

  defp seq(events), do: SeqAdvisor.evidence(events)

  defp storm do
    {n, gap, base, step} =
      {Enum.random(12..80), lu(500, 5_000), lu(20_000, 200_000), lu(500, 5_000)}

    for(i <- 1..n, do: call(pid(i), pid(0), i * gap, 0, i * 10, base + i * step))
    |> List.flatten()
    |> seq()
  end

  defp fan_out do
    {n, gap} = {Enum.random(8..60), lu(100, 2_000)}

    for(
      i <- 1..n,
      do:
        msg(
          pid(0),
          pid(i),
          pick([{:"$gen_cast", {:update, i}}, {:event, i}]),
          i * gap,
          {1, 1 + i}
        )
    )
    |> seq()
  end

  defp chatty do
    {n, gap} = {Enum.random(16..120), lu(200, 5_000)}

    for(
      i <- 1..n,
      do:
        if(rem(i, 2) == 0,
          do: msg(pid(1), pid(2), {:chunk, i}, i * gap, {i, i + 1}),
          else: msg(pid(2), pid(1), {:ack, i}, i * gap, {i, i + 1})
        )
    )
    |> seq()
  end

  defp chain do
    {chains, depth, gap} = {Enum.random(1..4), Enum.random(5..12), lu(500, 5_000)}

    for(
      c <- 0..(chains - 1),
      hop <- 0..(depth - 1),
      do:
        msg(
          pid(c * 20 + hop),
          pid(c * 20 + hop + 1),
          {:forward, c},
          c * 50_000 + hop * gap,
          {c * 100 + hop, c * 100 + hop + 1}
        )
    )
    |> seq()
  end

  defp slow do
    {answered, open, latency, gap} =
      {Enum.random(3..10), Enum.random(1..4), lu(300_000, 3_000_000), lu(50_000, 200_000)}

    calls = for i <- 1..answered, do: call(pid(i), pid(0), i * gap, 0, i * 10, latency * jit(0.2))

    unanswered =
      for i <- (answered + 1)..(answered + open) do
        ref = make_ref()
        msg(pid(i), pid(0), {:"$gen_call", {self(), [:alias | ref]}, :req}, i * gap, {0, i * 10})
      end

    seq(List.flatten(calls) ++ unanswered)
  end

  defp normal do
    {k, latency, gap} = {Enum.random(3..12), lu(100, 10_000), lu(50_000, 500_000)}

    for(
      i <- 1..k,
      do: call(pid(Enum.random(1..k)), pid(0), i * gap, 0, i * 10, latency * jit(0.3))
    )
    |> List.flatten()
    |> seq()
  end

  ## Triage

  @triage_classes [
    {"inspect_mailbox", 1},
    {"profile_cpu", 1},
    {"inspect_heap_growth", 1},
    {"review_idle_memory", 1},
    {"inspect_blocking", 1},
    {"no_clear_issue", 5}
  ]

  # `tables` random tables of 6 to 16 processes; one example per process
  defp triage(per_class) do
    tables = max(div(per_class * 10, 11), 1)
    Enum.flat_map(1..tables, fn _ -> triage_table() end)
  end

  defp triage_table do
    n = Enum.random(6..16)
    weighted = Enum.flat_map(@triage_classes, fn {c, w} -> List.duplicate(c, w) end)

    specs =
      for i <- 1..n do
        class = pick(weighted)
        {:c.pid(0, 700 + i, 0), class, triage_spec(class)}
      end

    procs_at = fn s ->
      for {pid, _class, f} <- specs do
        {memory, queue, _rate, status, current} = f.(s)

        %{
          pid: pid,
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

    rates_at = fn s -> Map.new(specs, fn {pid, _, f} -> {pid, elem(f.(s), 2)} end) end

    history =
      Enum.reduce(0..30//2, nil, fn s, h ->
        TriageAdvisor.track(h, procs_at.(s), rates_at.(s), s * 1_000_000)
      end)

    {state, _questions, ids} = TriageAdvisor.request(procs_at.(30), rates_at.(30), history)
    class_of = Map.new(specs, fn {pid, class, _} -> {pid, class} end)

    for {id, pid} <- ids do
      row = Map.put(state.processes[id], :observed_window_s, state.observed_window_s)
      {row, class_of[pid]}
    end
  end

  # fn s -> {memory, queue, rate, status, current}
  defp triage_spec("inspect_mailbox") do
    {base, g, r, rate} =
      {lu(50_000, 2_000_000), lu(5_000, 80_000), lu(3, 300), lu(2_000, 100_000)}

    loop = pick(@otp_loops)
    fn s -> {round(base + s * g), round(s * r), round(rate), :waiting, loop} end
  end

  defp triage_spec("profile_cpu") do
    {mem, rate} = {lu(20_000, 500_000), lu(150_000, 2_000_000)}
    current = pick([{:lists, :foldl, 3}, {:my_app, :compute, 2}])
    status = pick([:running, :runnable])
    fn _ -> {round(mem), 0, round(rate * jit(0.1)), status, current} end
  end

  defp triage_spec("inspect_heap_growth") do
    {base, g} = {lu(300_000, 5_000_000), lu(100_000, 2_000_000)}
    loop = pick(@otp_loops)
    fn s -> {round(base + s * g), 0, round(lu(500, 10_000)), :waiting, loop} end
  end

  defp triage_spec("review_idle_memory") do
    mem = round(lu(10_000_000, 200_000_000))
    loop = pick([{:erlang, :hibernate, 3} | @otp_loops])
    fn _ -> {mem, 0, 0, :waiting, loop} end
  end

  defp triage_spec("inspect_blocking") do
    {base, r} = {lu(30_000, 300_000), u(0.5, 6.0)}
    current = pick([{:my_client, :await, 2}, {:gen, :do_call, 4}])
    fn s -> {round(base + s * 500), round(s * r), 0, :waiting, current} end
  end

  defp triage_spec("no_clear_issue") do
    {mem, every, burst} = {lu(5_000, 1_000_000), Enum.random(3..12), lu(50, 5_000)}
    loop = pick([{:erlang, :hibernate, 3} | @otp_loops])
    fn s -> {round(mem), 0, if(rem(s, every) == 0, do: round(burst), else: 0), :waiting, loop} end
  end

  ## Random

  # uniform, log-uniform, ±pct jitter factor, one of
  defp u(lo, hi), do: lo + :rand.uniform() * (hi - lo)
  defp lu(lo, hi), do: :math.exp(u(:math.log(lo), :math.log(hi)))
  defp jit(pct), do: 1 + u(-pct, pct)
  defp pick(list), do: Enum.random(list)
end
