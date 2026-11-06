defmodule AshQuint.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/Torkan/ash_quint"

  def project do
    [
      app: :ash_quint,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description: "Replay Quint model traces against an Elixir/Ash system in ExUnit.",
      package: package(),
      docs: docs(),
      dialyzer: [plt_add_apps: [:mix, :ex_unit], plt_local_path: "priv/plts"]
    ]
  end

  def cli do
    [
      preferred_envs: [
        "test.generate_migrations": :test,
        "test.check_migrations": :test,
        "test.create": :test,
        "test.migrate": :test,
        "test.rollback": :test,
        "test.drop": :test,
        "test.reset": :test
      ]
    ]
  end

  def application do
    [
      mod: {AshQuint.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:ash, "~> 3.0", optional: true},
      {:telemetry, "~> 1.0", optional: true},
      {:ash_postgres, "~> 2.0", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      # Needs Elixir ~> 1.18; dev only, so the 1.17 floor applies to lib/.
      {:usage_rules, "~> 1.3", only: :dev, runtime: false}
    ]
  end

  # The :postgres tests' database (AshQuint.TestRepo); its migrations are
  # generated from the resources into priv/test_repo (not packaged).
  defp aliases do
    [
      "test.generate_migrations": "ash_postgres.generate_migrations",
      "test.check_migrations": "ash_postgres.generate_migrations --check",
      "test.create": "ash_postgres.create",
      "test.migrate": "ash_postgres.migrate",
      "test.rollback": "ash_postgres.rollback",
      "test.drop": "ash_postgres.drop",
      "test.reset": ["test.drop", "test.create", "test.migrate"]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files:
        ~w(lib priv/examples/counter priv/examples/race mix.exs README.md LICENSE CHANGELOG.md
           usage-rules.md usage-rules)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"],
      groups_for_modules: [
        Core: [
          AshQuint,
          AshQuint.Case,
          AshQuint.Adapter,
          AshQuint.Gate,
          AshQuint.Gate.Telemetry,
          AshQuint.Names,
          AshQuint.Replay,
          AshQuint.Sensitivity,
          AshQuint.Trace,
          AshQuint.Step,
          AshQuint.ITF,
          AshQuint.ITF.Error
        ],
        Ash: [AshQuint.Ash, AshQuint.Ash.Gate],
        Mix: [
          Mix.Tasks.AshQuint.Gen,
          AshQuint.Gen,
          Mix.Tasks.AshQuint.Promote,
          Mix.Tasks.AshQuint.Explore,
          AshQuint.Explore,
          AshQuint.Shrink,
          Mix.Tasks.AshQuint.Gen.Adapter,
          AshQuint.Scaffold,
          Mix.Tasks.AshQuint.Coverage,
          AshQuint.Coverage,
          AshQuint.Config,
          AshQuint.Config.Model,
          AshQuint.Manifest,
          AshQuint.Interface
        ]
      ]
    ]
  end
end
