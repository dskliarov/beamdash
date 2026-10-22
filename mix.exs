defmodule Beamdash.MixProject do
  use Mix.Project

  def project do
    [
      app: :beamdash,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      mod: {Beamdash.Application, []},
      extra_applications: [:logger, :runtime_tools, :inets, :ssl]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # No Node.js toolchain: the Phoenix and LiveView JS are served straight
  # from the deps' priv/static folders (see BeamdashWeb.Endpoint).
  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.1"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"},
      # loaded into the target for the Memory page (unless it has its own)
      {:recon, "~> 2.5"}
    ]
  end

  defp aliases do
    [setup: ["deps.get", "compile"]]
  end
end
