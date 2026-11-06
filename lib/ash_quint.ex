defmodule AshQuint do
  @moduledoc """
  Replay the traces of a Quint model against the real system in ExUnit.

  ash_quint decodes Quint ITF traces, runs each model step through a
  per-model adapter, and checks the outcome, the state the step covers and
  the model's invariants after every step. Traces are generated once with a
  pinned Quint by `mix ash_quint.gen` and committed, so the test suite needs
  neither Node nor Quint. The README is the guide.

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
    * `AshQuint.Manifest` — `<out>/manifest.json`.
    * `mix ash_quint.coverage` (`Mix.Tasks.AshQuint.Coverage`) and
      `AshQuint.Coverage` — which outcomes each action reaches in the
      committed traces.
    * `mix ash_quint.gen.adapter` (`Mix.Tasks.AshQuint.Gen.Adapter`) and
      `AshQuint.Scaffold` — an adapter skeleton and its test module, from
      the model interface in the manifest.
  """
end
