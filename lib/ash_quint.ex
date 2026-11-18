defmodule AshQuint do
  @moduledoc """
  Replay the traces of a Quint model against the real system in ExUnit.

  ash_quint decodes Quint ITF traces, runs each model step through a
  per-model adapter, and checks the outcome, the state the step covers and
  the model's invariants after every step. Traces are generated once with a
  pinned Quint by `mix ash_quint.gen` and committed, so the test suite needs
  neither Node nor Quint. The README is the guide.

  ## Enabling

  ash_quint is inert unless the environment enables it, usually in
  `config/test.exs`:

      config :ash_quint, enabled: true

  Elsewhere (dev, prod) gates (`AshQuint.Gate.checkpoint/1`, the Ash change
  `AshQuint.Ash.Gate`) compile to no-ops, the application starts nothing,
  and replays raise. So gates can stay in the system's code in every
  environment. The setting is read at compile time; Mix recompiles
  ash_quint when it changes.

  ## Modules

  Writing tests:

    * `AshQuint.Case` — one ExUnit test per committed trace, a staleness
      test and the optional sensitivity test.
    * `AshQuint.Adapter` — the behaviour connecting a model to the system.
    * `AshQuint.Names` — maps the model's small values to real ones, per
      trace.
    * `AshQuint.Ash` — helpers for adapters over Ash resources (only with
      `ash`).

  Under the hood:

    * `AshQuint.Replay` — replays one trace through an adapter.
    * `AshQuint.Sensitivity` — mutants that a meaningful replay must fail.
    * `AshQuint.Trace`, `AshQuint.Step` and `AshQuint.ITF` — decoded traces
      and steps.

  Generating traces:

    * `mix ash_quint.gen` (`Mix.Tasks.AshQuint.Gen`) and `AshQuint.Gen` —
      run Quint and write the traces.
    * `AshQuint.Config` — `ash_quint.exs`.
    * `AshQuint.Manifest` — `<out>/manifest.json`, and `AshQuint.Interface`,
      the model interface it records.
    * `mix ash_quint.explore` (`Mix.Tasks.AshQuint.Explore`) and
      `AshQuint.Explore` — replay fresh traces and report failures as
      candidate regression traces, shrunk with `shrink:`
      (`AshQuint.Shrink`); `mix ash_quint.promote`
      (`Mix.Tasks.AshQuint.Promote`) commits them.
    * `mix ash_quint.coverage` (`Mix.Tasks.AshQuint.Coverage`) and
      `AshQuint.Coverage` — which outcomes each action reaches in the
      committed traces.
    * `mix ash_quint.gen.adapter` (`Mix.Tasks.AshQuint.Gen.Adapter`) and
      `AshQuint.Scaffold` — an adapter skeleton and its test module, from
      the model interface in the manifest.
  """

  @enabled Application.compile_env(:ash_quint, :enabled, false) == true

  @doc """
  Whether ash_quint is enabled in this environment
  (`config :ash_quint, enabled: true`, read at compile time). See
  "Enabling" above.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: @enabled

  @doc false
  # Raises unless ash_quint is enabled: replays and telemetry gates refuse
  # to run where gates are no-ops.
  @spec ensure_enabled!() :: :ok | no_return()
  if @enabled do
    def ensure_enabled!, do: :ok
  else
    def ensure_enabled! do
      raise "ash_quint is disabled in this environment: " <>
              "add `config :ash_quint, enabled: true` to config/test.exs"
    end
  end
end
