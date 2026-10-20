defmodule Mix.Tasks.Exberly.JevEval do
  @shortdoc "Checks Jev's suggestions against fixed scenarios"
  @moduledoc """
  Sends each scenario in `Exberly.Jev.Scenarios` (synthetic processes
  with a known right answer) to Jev and reports how many it gets right.
  Run it before changing `TYPESAFE_MODEL`, and compare.

      TYPESAFE_API_KEY=... mix exberly.jev_eval
      TYPESAFE_API_KEY=... mix exberly.jev_eval --model jev-latest --strict

  `--strict` exits with status 1 if any scenario is missed. Each scenario
  is one request and may be charged. `--only memory,seq` runs
  only those sets (process, gc, memory, seq, route, triage).
  """
  use Mix.Task

  alias Exberly.{GCAdvisor, Jev, ProcessAdvisor}
  alias Exberly.Jev.{MoreScenarios, Scenarios}

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [model: :string, strict: :boolean, only: :string])

    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started([:inets, :ssl])

    unless Jev.configured?(), do: Mix.raise("Set TYPESAFE_API_KEY first.")

    model = opts[:model] || Jev.model()
    only = if o = opts[:only], do: o |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    Mix.shell().info("Jev scenarios · model #{model}\n")

    scenarios =
      (Scenarios.all() ++ MoreScenarios.all())
      |> Enum.filter(&(only == nil or Atom.to_string(&1.advisor) in only))

    results =
      for s <- scenarios do
        case check(s, model: model) do
          {:ok, ok, got} ->
            Mix.shell().info(
              "#{if ok, do: "ok  ", else: "MISS"} #{s.advisor}/#{s.name}: #{got}" <>
                if(ok, do: "", else: " · expected #{expected(s)}")
            )

            ok

          {:error, message} ->
            Mix.shell().error("ERR  #{s.advisor}/#{s.name}: #{message}")
            false
        end
      end

    right = Enum.count(results, & &1)
    Mix.shell().info("\n#{right} of #{length(results)} right")
    if opts[:strict] && right < length(results), do: exit({:shutdown, 1})
  end

  @advisors %{
    process: ProcessAdvisor,
    gc: GCAdvisor,
    memory: Exberly.MemoryAdvisor,
    seq: Exberly.SeqAdvisor
  }

  defp check(%{advisor: :route} = s, opts) do
    with {:ok, a} <- Exberly.AskAdvisor.ask(s.evidence, nil, opts),
         do: {:ok, a.choice in s.expect, a.choice}
  end

  # right when the flagged processes are exactly the expected ones
  defp check(%{advisor: :triage} = s, opts) do
    {_state, _questions, ids} = s.evidence

    with {:ok, t} <- Exberly.TriageAdvisor.analyze(s.evidence, opts) do
      flagged =
        for({id, pid} <- ids, t.results[pid] && t.results[pid].flagged, do: id) |> Enum.sort()

      {:ok, flagged == s.expect, "flagged #{Enum.join(flagged, " ")}"}
    end
  end

  defp check(s, opts) do
    with {:ok, a} <- @advisors[s.advisor].analyze(s.evidence, opts) do
      alt = if a.alternative, do: " (or #{a.alternative.key})", else: ""

      {:ok, a.choice in s.expect,
       "#{a.choice}#{alt} · confidence #{Float.round(a.confidence * 1.0, 2)}"}
    end
  end

  defp expected(%{advisor: :triage, expect: ids}), do: "flagged " <> Enum.join(ids, " ")
  defp expected(s), do: Enum.join(s.expect, " or ")
end
