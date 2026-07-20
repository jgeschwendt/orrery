defmodule Orrery.MixProject do
  use Mix.Project

  def project do
    [
      app: :orrery,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      listeners: [Phoenix.CodeReloader],
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {OrreryWeb.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:bandit, "~> 1.5"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:file_system, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix, "~> 1.8.8"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind orrery", "esbuild orrery"],
      "assets.deploy": [
        "tailwind orrery --minify",
        "esbuild orrery --minify",
        "phx.digest"
      ],
      # test runs in a fresh process with MIX_ENV exported: `preferred_envs` switches
      # Mix.env() only after mix.exs is evaluated, so `elixirc_paths(Mix.env())` resolves
      # against :dev and test/support never compiles for the in-process `test` task.
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "cmd env MIX_ENV=test mix test"
      ]
    ]
  end
end
