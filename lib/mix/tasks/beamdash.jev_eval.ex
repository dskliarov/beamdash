defmodule Mix.Tasks.Beamdash.JevEval do
  @shortdoc "Checks Jev's suggestions against fixed scenarios"
  @moduledoc """
  Sends each scenario in `Beamdash.Jev.Scenarios` (synthetic processes
  with a known right answer) to Jev and reports how many it gets right.
  Run it before changing `TYPESAFE_MODEL`, and compare.

      TYPESAFE_API_KEY=... mix beamdash.jev_eval
      TYPESAFE_API_KEY=... mix beamdash.jev_eval --model jev-latest --strict

  `--strict` exits with status 1 if any scenario is missed. Each scenario
  is one request and may be charged. `--only memory,seq` runs
  only those sets (process, gc, memory, seq, route, triage).

  `--backend kev` sends the same scenarios to the Kev server at `KEV_URL`
  instead, `--backend nx` asks beamdash's local Nx model (`mix
  beamdash.nx_train`; it cannot answer the typed questions) and
  `--backend jev` forces Jev; the default is the backend in use.
  Each line shows how long its request took, and the summary the mean and
  slowest, to compare speed as well as answers.

      KEV_URL=http://127.0.0.1:8009 mix beamdash.jev_eval --backend kev
  """
  use Mix.Task

  alias Beamdash.{GCAdvisor, Jev, ProcessAdvisor}
  alias Beamdash.Jev.{MoreScenarios, Scenarios}

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [model: :string, strict: :boolean, only: :string, backend: :string]
      )

    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started([:inets, :ssl])

    backend =
      case opts[:backend] do
        nil -> Jev.backend()
        "jev" -> :jev
        "kev" -> :kev
        "nx" -> :nx
        other -> Mix.raise("--backend is jev, kev or nx, not #{other}")
      end

    # asked for by name, the local model needs no NX_MODEL
    if backend == :nx do
      config = Application.get_env(:beamdash, Jev, [])
      Application.put_env(:beamdash, Jev, Keyword.put(config, :nx, true))
    end

    unless Jev.configured?(backend) do
      Mix.raise(
        case backend do
          :kev -> "Set KEV_URL first."
          :nx -> "Train the local model first: mix beamdash.nx_train."
          :jev -> "Set TYPESAFE_API_KEY first."
        end
      )
    end

    model = opts[:model] || Jev.model(backend)
    only = if o = opts[:only], do: o |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    Mix.shell().info(
      "#{Jev.name(backend)} scenarios · #{Jev.endpoint(backend)} · model #{model}\n"
    )

    scenarios =
      (Scenarios.all() ++ MoreScenarios.all())
      |> Enum.filter(&(only == nil or Atom.to_string(&1.advisor) in only))

    results =
      for s <- scenarios do
        {us, result} = :timer.tc(fn -> check(s, model: model, backend: backend) end)
        ms = div(us, 1000)

        case result do
          {:ok, ok, got} ->
            Mix.shell().info(
              "#{if ok, do: "ok  ", else: "MISS"} #{s.advisor}/#{s.name}: #{got}" <>
                if(ok, do: "", else: " · expected #{expected(s)}") <> " · #{ms} ms"
            )

            {ok, ms}

          {:error, message} ->
            Mix.shell().error("ERR  #{s.advisor}/#{s.name}: #{message} · #{ms} ms")
            {false, ms}
        end
      end

    right = Enum.count(results, &elem(&1, 0))
    times = Enum.map(results, &elem(&1, 1))
    Mix.shell().info("\n#{right} of #{length(results)} right")

    if times != [] do
      Mix.shell().info(
        "request time: mean #{div(Enum.sum(times), length(times))} ms, slowest #{Enum.max(times)} ms"
      )
    end

    if opts[:strict] && right < length(results), do: exit({:shutdown, 1})
  end

  @advisors %{
    process: ProcessAdvisor,
    gc: GCAdvisor,
    memory: Beamdash.MemoryAdvisor,
    seq: Beamdash.SeqAdvisor
  }

  defp check(%{advisor: :route} = s, opts) do
    with {:ok, a} <- Beamdash.AskAdvisor.ask(s.evidence, nil, opts),
         do: {:ok, a.choice in s.expect, a.choice}
  end

  # right when the flagged processes are exactly the expected ones
  defp check(%{advisor: :triage} = s, opts) do
    {_state, _questions, ids} = s.evidence

    with {:ok, t} <- Beamdash.TriageAdvisor.analyze(s.evidence, opts) do
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
