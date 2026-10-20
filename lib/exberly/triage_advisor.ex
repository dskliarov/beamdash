defmodule Exberly.TriageAdvisor do
  @moduledoc """
  Triage of the Processes table with Jev: for the busiest processes (top
  by memory, message queue and reductions rate) one request asks, per
  process, which investigation should come next, with the same options as
  the process panel (`Exberly.ProcessAdvisor`), "No clear issue"
  included. A process is flagged when its top answer is an investigation.

  Processes are sent as anonymous ids (`p1`, `p2`, …) mapped back here;
  their facts are computed here from a rolling table history (memory and
  queue trends, reductions rate, rank on the node, OTP kind, a wait
  category). No pids, names, modules or functions are sent.
  """
  alias Exberly.{Jev, ProcessAdvisor}
  alias Exberly.Jev.Features, as: F

  @per_measure 10
  @max_candidates 30
  @keep 16
  @min_samples 8
  @min_window_s 14
  @flag_at 0.5

  @doc "At most this many processes are triaged at once."
  def max_candidates, do: @max_candidates

  @doc """
  The processes worth tracking: the top #{@per_measure} by memory, by
  message queue and by reductions rate (with a queue or a rate), at most
  #{@max_candidates}; exberly's own helpers on the node are left out.
  """
  def candidates(procs, rates) do
    procs = Enum.reject(procs, &own?/1)

    top = fn key_fun ->
      procs
      |> Enum.filter(&((key_fun.(&1) || 0) > 0))
      |> Enum.sort_by(&(key_fun.(&1) || 0), :desc)
      |> Enum.take(@per_measure)
      |> Enum.map(& &1.pid)
    end

    (top.(& &1.memory) ++ top.(& &1.message_queue_len) ++ top.(&rates[&1.pid]))
    |> Enum.uniq()
    |> Enum.take(@max_candidates)
  end

  @doc """
  Adds one table sample (taken at `at_us`) to `history`
  (`%{samples: [at_us], procs: %{pid => [point]}}`), keeping the last
  #{@keep} samples and only the current candidates.
  """
  def track(history, procs, rates, at_us) do
    history = history || %{samples: [], procs: %{}}
    ids = candidates(procs, rates)
    by_pid = Map.new(procs, &{&1.pid, &1})

    points =
      Map.new(ids, fn pid ->
        p = by_pid[pid]

        point = %{
          at_us: at_us,
          memory: p.memory,
          queue: p.message_queue_len,
          rate: rates[pid]
        }

        {pid, Enum.take(Map.get(history.procs, pid, []) ++ [point], -@keep)}
      end)

    %{samples: Enum.take(history.samples ++ [at_us], -@keep), procs: points}
  end

  # exberly's own helpers on the target (trace collectors, the sys:trace
  # collector) are not the user's processes
  defp own?(%{registered_name: name}) when is_atom(name) and name != nil do
    n = Atom.to_string(name)
    String.starts_with?(n, "erlyberly") or String.starts_with?(n, "exberly")
  end

  defp own?(_), do: false

  @doc "`{:ready, s}` or `{:collecting, s, needed}` from the table history."
  def readiness(nil), do: {:collecting, 0, @min_window_s + 1}

  def readiness(%{samples: samples}) do
    s =
      case samples do
        [first | _] -> div(List.last(samples) - first, 1_000_000)
        [] -> 0
      end

    if length(samples) >= @min_samples and s >= @min_window_s,
      do: {:ready, s},
      else: {:collecting, s, @min_window_s + 1}
  end

  @doc """
  `{state, questions, ids}`: the state sent to Jev, one question per
  tracked process, and `%{"p1" => pid}` to map answers back.
  """
  def request(procs, rates, history) do
    by_pid = Map.new(procs, &{&1.pid, &1})

    rows =
      for p <- procs,
          do: %{
            pid: p.pid,
            memory: p.memory,
            queue: p.message_queue_len,
            rate: rates[p.pid],
            kind: Map.get(p, :kind)
          }

    tracked =
      history.procs
      |> Enum.filter(fn {pid, points} -> Map.has_key?(by_pid, pid) and points != [] end)
      # numbered in pid order: an id says nothing about size or rank
      |> Enum.sort_by(fn {pid, _} -> pid end)

    ids = tracked |> Enum.with_index(1) |> Map.new(fn {{pid, _}, i} -> {"p#{i}", pid} end)
    id_of = Map.new(ids, fn {id, pid} -> {pid, id} end)

    processes =
      Map.new(tracked, fn {pid, points} ->
        {id_of[pid], features(by_pid[pid], points, F.node_context(rows, pid))}
      end)

    state = %{
      processes_on_node: length(procs),
      observed_window_s: window(history.samples),
      processes: processes
    }

    questions =
      Map.new(ids, fn {id, _pid} ->
        {id,
         {%{
            question:
              "Which investigation, if any, should come next for process `#{id}` (in `processes`)?",
            rules: [
              "Judge only `#{id}`; the other processes are context.",
              "Growth figures are per second over observed_window_s; ranks and shares are percentages.",
              "Reductions are units of work, not CPU time.",
              "Waiting in an OTP receive loop with an empty queue is normal idleness.",
              "Choose no_clear_issue unless the measurements point to a problem."
            ]
          }, ProcessAdvisor.choices()}}
      end)

    {state, questions, ids}
  end

  @doc """
  Asks Jev; returns `{:ok, %{results: %{pid => verdict}, model, at, count}}`
  where a verdict is `%{flagged, choice, label, worth, alternative}` and
  `worth` is 1 − the probability of "No clear issue".
  """
  def analyze({state, questions, ids}, opts \\ []) do
    with {:ok, answers} <- Jev.ask_many(state, questions, opts) do
      results =
        Map.new(answers, fn {id, a} ->
          worth = 1 - prob(a, "no_clear_issue")
          top = a.ranking |> Enum.reject(&(&1.key == "no_clear_issue")) |> hd()

          {ids[id],
           %{
             flagged: a.choice != "no_clear_issue" and worth >= @flag_at,
             choice: top.key,
             label: top.label,
             worth: worth,
             alternative:
               if(a.alternative && a.alternative.key != "no_clear_issue", do: a.alternative)
           }}
        end)

      model = answers |> Map.values() |> List.first() |> then(&(&1 && &1.model))

      {:ok,
       %{
         results: results,
         model: model,
         at: DateTime.utc_now(),
         count: map_size(results),
         window_s: state.observed_window_s
       }}
    end
  end

  defp prob(answer, key),
    do: Enum.find_value(answer.ranking, 0, &(&1.key == key && &1.probability))

  defp features(proc, points, context) do
    t0 = hd(points).at_us
    t = fn p -> (p.at_us - t0) / 1_000_000 end
    rates = points |> Enum.map(& &1.rate) |> Enum.filter(&is_number/1)

    %{
      status: proc.status,
      waiting_in: F.wait_category(proc.status, proc[:current_function]),
      memory_bytes: proc.memory,
      memory_change_pct: F.change_pct(Enum.map(points, & &1.memory)),
      memory_growth_bytes_per_s: F.slope(Enum.map(points, &{t.(&1), &1.memory})),
      queued_now: proc.message_queue_len,
      queue_growth_per_s: F.slope(Enum.map(points, &{t.(&1), &1.queue})),
      reductions_per_s_now: List.last(points).rate,
      reductions_per_s_mean: F.mean(rates),
      node: context
    }
  end

  defp window([]), do: 0
  defp window([first | _] = s), do: div(List.last(s) - first, 1_000_000)
end
