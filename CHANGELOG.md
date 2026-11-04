# Changelog

## Unreleased

- `AshQuint.Adapter` has an optional `finish/2`, which `AshQuint.Replay`
  calls once when a replay ends, pass or fail (also before an adapter
  exception propagates), with the latest `ctx`. Use it to release what a
  replay holds open, which matters for the sensitivity check's failing
  mutants, and for end-of-trace checks: `{:error, message}` fails a passing
  replay at its last step.
- `mix ash_quint.coverage [model ...]` prints, from the committed
  manifests (no Node or Quint), which outcomes each model action reaches
  across the traces (`Inc  23  accepted 20  rejected:over_limit 3`), so
  unreached paths show at a glance. `mix ash_quint.gen` prints the same
  table after writing a model. Results are labelled `accepted` and
  `rejected:<code>` (`AshQuint.Step.result_label/1`).
- The manifest is format 2: each trace records `outcomes`, the result
  labels counted per action (empty for models without `lastResult`).
  Format 1 manifests still decode and replay; `mix ash_quint.coverage`
  asks to regenerate them, and `mix ash_quint.gen --check` reports them
  as changed.
- `AshQuint.Config.select!/2` selects models by name, for Mix tasks.
- `allow_untested` takes `~w(...)` and `~W(...)` sigils as well as literal
  lists of strings.
- The model convention for concurrency: a start action sets
  `lastResult' = Pending` and the action names its call with an `op` field;
  the completing action has the outcome. `AshQuint.Step` decodes `Pending`
  to `:pending` and the op into `step.op`; models set the names with
  `pending_result:` and `op_field:` (default `"Pending"` and `"op"`).
  `AshQuint.Replay` takes both as options.
- Manifest entries (format 2) of traces with a call in flight have
  `"concurrent": true` and `"max_in_flight"`. Both are optional on read, so
  sequential models' manifests are unchanged. `Pending` steps count as
  `pending` in `outcomes`, `AshQuint.Step.result_label/1` and the coverage
  table.
- `priv/examples/race`: a model of two concurrent `Inc`s against a limit,
  with committed traces.
- Replays are still sequential. The interleaved-trace failure now points at
  the planned `{:start, …}`/`{:complete, …}` API, and a `Pending` step
  whose `step/2` returns `{:ok, …}` or `{:skip, …}` fails.

## 0.1.0

First release.

- `AshQuint.ITF` decodes Quint ITF traces: every ITF form, variants,
  qualified variable names, and the bignumber.js objects Quint 0.33 writes
  for integers with |n| ≥ 10^15. No atoms are created from trace data.
- The model convention: `lastAction` (required) and `lastResult`
  (optional), with configurable paths and initial action.
- `AshQuint.Adapter` with `:ok`, `:pending` and `:skip` steps, optional
  `expected/2`, `outcome/1` and `invariants/0`, and `AshQuint.Names`.
- `AshQuint.Replay`: sequential replay with outcome, state and invariant
  checks, and failures naming the trace, step, action and seed.
- `mix ash_quint.gen` generates random, witness and scenario traces with a
  pinned Quint version (run through npx by default), reproducibly from
  the model's seed, with `--check` and `--dry-run`. `random:` and `witnesses:`
  take `init:` and `step:`.
- `AshQuint.Case` defines a test per committed trace and a staleness test,
  with `on_missing_model: :skip` for uncommitted models.
- `AshQuint.Sensitivity` and `sensitivity: true | [allow_untested: …]`:
  perturbed-expectation and dropped-call mutants, and untested keys and
  actions.
- `AshQuint.Ash` helpers: `outcome/2`, `read_map/2`, `sql_rows/3`. Ash is
  optional.
- Requires Elixir 1.17 or later.
