defmodule HelloPlugin.MixProject do
  use Mix.Project

  def project do
    [
      app: :hello_plugin,
      version: "0.1.0",
      elixir: "~> 1.15",
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:hello_app, "~> 1.0", runtime: false},
      {:phoenix_live_view, "~> 1.0"},
      {:beamdash, path: "../../../..", only: [:dev, :test], runtime: false}
    ]
  end
end
