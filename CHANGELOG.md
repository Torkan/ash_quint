# Changelog

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
