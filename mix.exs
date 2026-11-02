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
      description: "Replay Quint model traces against an Elixir/Ash system in ExUnit.",
      package: package(),
      docs: docs(),
      dialyzer: [plt_add_apps: [:mix, :ex_unit], plt_local_path: "priv/plts"]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:ash, "~> 3.0", optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv/examples/counter mix.exs README.md LICENSE CHANGELOG.md)
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
          AshQuint.Names,
          AshQuint.Replay,
          AshQuint.Sensitivity,
          AshQuint.Trace,
          AshQuint.Step,
          AshQuint.ITF,
          AshQuint.ITF.Error
        ],
        Ash: [AshQuint.Ash],
        Mix: [
          Mix.Tasks.AshQuint.Gen,
          AshQuint.Gen,
          AshQuint.Config,
          AshQuint.Config.Model,
          AshQuint.Manifest
        ]
      ]
    ]
  end
end
