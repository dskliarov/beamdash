defmodule Mix.Tasks.Beamdash.NxTrain do
  @shortdoc "Trains beamdash's local Nx suggestion model"
  @moduledoc """
  Trains `Beamdash.Insights.Model` (the `nx` backend of the suggestion
  panels) on generated examples (`Beamdash.Insights.Training`) and writes
  `priv/nx/models.etf`.

      mix beamdash.nx_train
      mix beamdash.nx_train --per-class 200 --iterations 300 --seed 3

  It then reports each model's accuracy on fresh examples from another
  seed, and on the fixed eval scenarios (never used for training); `mix
  beamdash.jev_eval --backend nx` checks the written model the same way
  as Jev and Kev. Training runs on Nx's binary backend and takes a few
  minutes.
  """
  use Mix.Task

  alias Beamdash.Insights.{Model, Training}

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [per_class: :integer, iterations: :integer, seed: :integer, alpha: :float]
      )

    Mix.Task.run("app.config")

    train_opts =
      [
        per_class: opts[:per_class] || 120,
        iterations: opts[:iterations] || 150,
        seed: opts[:seed] || 1,
        alpha: opts[:alpha] || 0.01,
        progress: &Mix.shell().info/1
      ]

    {us, models} = :timer.tc(fn -> Training.train_all(train_opts) end)
    Mix.shell().info("trained in #{div(us, 1_000_000)} s\n")

    for kind <- Training.kinds() do
      held_out = Training.generate(kind, 40, train_opts[:seed] + 1000)
      {acc, misses} = Training.evaluate(models.kinds[kind], held_out)

      Mix.shell().info(
        "#{kind}: #{Float.round(acc * 100, 1)}% of #{length(held_out)} fresh examples" <>
          if(misses == %{}, do: "", else: " · misses #{inspect(Enum.take(misses, 4))}")
      )
    end

    path = Path.join(["priv", "nx", "models.etf"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :erlang.term_to_binary(models, [:compressed]))
    Model.put_models(models)
    Mix.shell().info("\nwrote #{path} (#{div(File.stat!(path).size, 1024)} KB)")
  end
end
