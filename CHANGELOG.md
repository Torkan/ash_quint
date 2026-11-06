# Changelog

## Unreleased

- Adapter scaffold: `mix ash_quint.gen.adapter <model> [--adapter Module]
  [--force]` writes `test/support/<model>_trace.ex`, an adapter with a
  `step/2` clause per action binding its picks (`{:start, …}` and
  `{:complete, …}` for concurrent actions, from the manifest's outcomes),
  `project/1` with every model variable and a `todo!/1` that raises
  `<adapter>: <what> is not implemented yet`, and
  `test/<model>_trace_test.exs`, its `AshQuint.Case` test module with
  `sensitivity: true`. It reads the model interface from a format 3
  manifest; `AshQuint.Scaffold` renders both files.
- Exploring: `use AshQuint.Case, explore: true` (or
  `[max_steps: …, batch: …]`) defines an `"explore <model>"` test, tagged
  `quint_explore: <model>`, that replays fresh `quint run` traces of the
  model's `random:` source in batches of consecutive seeds
  (`AshQuint.Explore`). A failing trace is cut after its failing step,
  confirmed by a second replay and written with its provenance to
  `_build/<env>/ash_quint/explore/<model>/` as a candidate for
  `mix ash_quint.promote`. `mix ash_quint.explore [model ...] [--runs]
  [--seed] [--budget] [--failures]` runs these tests with the settings in
  `ASH_QUINT_EXPLORE*` variables. Exclude `:quint_explore` in
  `test/test_helper.exs`: run without `ASH_QUINT_EXPLORE=1`, the test
  fails. `AshQuint.Gen.random_args/3` builds the `quint run` arguments
  that gen and explore share.
- Regression traces: `mix ash_quint.promote <candidate> ...` commits a
  trace with its provenance in `#meta.ash_quint` (model, model hash, seed,
  index) as `<out>/regression_<seed>_<index>.itf.json`, byte for byte, and
  adds its entry to the manifest: source `regression`, with the entry's
  own `seed`. `AshQuint.Case` generates a `"regression <seed>_<index>"`
  test for it, tagged `quint: :regression` and replayed with that seed.
  `mix ash_quint.gen` keeps regression files as they are, notes one found
  against an earlier model, and refuses one without provenance, one that
  isn't JSON or one the model no longer reads. Promote refuses a target
  the manifest still lists after its file was deleted. Manifest entries
  may carry an integer `seed`, and two entries for one file are a decode
  error; `AshQuint.Gen` gains `provenance/1`, `put_provenance/2`,
  `regression_file/2` and `regression_entry!/3`, and its `generated` map
  `notes`.
- For Mix tasks and tooling: `AshQuint.Manifest.load/3` reads a model's
  manifest, with errors that ask for a regeneration (`need: :outcomes` or
  `:interface`; a manifest from a newer ash_quint asks for an upgrade
  instead); `AshQuint.Config.Model.replay_opts/1` gives a model's replay
  options; `AshQuint.Step.roots/1` the action and result roots;
  `AshQuint.Gen.run_quint/3` runs the configured Quint in the project
  root, and `AshQuint.Gen.interface_command/3` is the `quint compile`
  command gen runs for the interface (a new `:interface` kind of
  `t:AshQuint.Gen.command/0`).
- The manifest is format 3. Each trace records `outcomes`, the result
  labels counted per action (empty for models without `lastResult`), and
  the manifest records the model's `interface`: `mix ash_quint.gen` runs
  `quint compile --target=json` for each model after its traces and reads
  its actions with their pick shapes (`unit`, `record` with typed fields,
  `value` or `map`), its result variants and its other variables, with
  types as Quint text (`AshQuint.Interface`). A failing compile, or a
  JSON IR whose shape the interface can't be read from, is a gen error.
  Older manifests still decode and replay: format 1 (0.1.0) without
  outcomes, format 2 without an interface. `mix ash_quint.coverage` asks
  to regenerate a format 1 manifest, and `mix ash_quint.gen --check`
  reports both as changed.
- **Breaking:** the sensitivity check reports model variables that no
  projection covers (`variable "inflight" is never projected`, target
  `{:var, name}`): the traces' variables, without the action and result
  roots, that are never a key of the replay's expected values. A suite
  whose model has a variable the adapter doesn't project (in-flight
  bookkeeping, model-only state) now fails its sensitivity test. Project
  the variable, or allow-list it with `vars:`:
  `sensitivity: [allow_untested: [vars: ~w(inflight finished)]]`. A
  `vars:` entry that is projected, or isn't a model variable, fails the
  test like other stale entries.
- A long mismatch on a projected key whose values are both maps (or both
  `MapSet`s) lists only the differing entries, with their key paths
  (`"c4" > "limit": expected 3, actual 5`), instead of both values whole.
  Short values keep the `expected:`/`actual:` form.
- `AshQuint.Adapter` has an optional `finish/2`, which `AshQuint.Replay`
  calls once when a replay ends, pass or fail (also before an adapter
  exception propagates), with the latest `ctx`. Use it to release what a
  replay holds open, which matters for the sensitivity check's failing
  mutants, and for end-of-trace checks: `{:error, message}` fails a passing
  replay at its last step.
- `mix ash_quint.coverage [model ...]` prints, from the committed
  manifests (no Node or Quint), which outcomes each model action reaches
  across the traces (`Inc  23  accepted 20  rejected:over_limit 3`), so
  unreached paths show at a glance. Every action of the model's interface
  but the init action has a row; one no trace takes has 0 steps
  (`Undo    0`). `mix ash_quint.gen` prints the same table after writing a
  model. Results are labelled `accepted` and `rejected:<code>`
  (`AshQuint.Step.result_label/1`). `AshQuint.Coverage.from_manifest/2`
  takes `init_action:`, and its coverage has `all_actions`: a format 2
  manifest's table lists the taken actions only and ends with a note
  asking for a regeneration.
- `AshQuint.Config.select!/2` selects models by name, for Mix tasks.
- `allow_untested` takes `~w(...)` and `~W(...)` sigils as well as literal
  lists of strings.
- The model convention for concurrency: a start action sets
  `lastResult' = Pending` and the action names its call with an `op` field;
  the completing action has the outcome. `AshQuint.Step` decodes `Pending`
  to `:pending` and the op into `step.op`; models set the names with
  `pending_result:` and `op_field:` (default `"Pending"` and `"op"`).
  `AshQuint.Replay` takes both as options.
- Manifest entries of traces with a call in flight have
  `"concurrent": true` and `"max_in_flight"`. Both are optional on read, so
  sequential models' manifests are unchanged. `Pending` steps count as
  `pending` in `outcomes`, `AshQuint.Step.result_label/1` and the coverage
  table.
- `priv/examples/race`: a model of two concurrent `Inc`s against a limit,
  with committed traces.
- Concurrent replay. `step/2` can return `{:start, op, call, ctx}`,
  `{:advance, op, ctx}` and `{:complete, op, ctx}` (with options `early:`,
  `may_block:` and `at:`): the replay runs `call` in an op task, holds it at
  `AshQuint.Gate.checkpoint/1` gates while other steps run, releases it
  where the trace says and checks its outcome at the completing step. Every
  step's state is compared once the ops in flight have settled. The model
  and the adapter must agree on which steps are `Pending`. A synchronous
  step blocked by a gated op is released by a watchdog and fails; a trace
  that ends with ops in flight passes, the ops cancelled. Every op task is
  stopped before `finish/2`. New `AshQuint.Replay.run/3` options:
  `settle_timeout`, `step_timeout`, `complete_timeout` and `gate_timeout`.
  Failures with ops in flight say where each op is, also in the failure's
  `in_flight`. `{:pending, ctx}` keeps its sequential rules; their failures
  now point at `{:start, …}`. The `race` example replays against an ETS
  resource (`test/support/race_adapter.ex`), and the lost update of its
  read-modify-write action fails `raceTest` at step 4.
- `:ash_quint` is now an OTP application: it starts the gate table.
- Sensitivity with concurrent traces. An op's completion and its start
  are calls the dropped-call mutant can drop (a start counts as changing
  the state when its op's completion does); `AshQuint.Replay`'s
  `{:drop, index}` on a `Pending` step drops its op, whose later advances
  and completion sync as skips. A new mutant, `{:serialize, index}` in
  `AshQuint.Replay`, runs an overlapping op to completion at its start: per
  start action, it must be detected in some overlapping trace, or the
  action's interleaving is untested (`serializing IncStart is never
  detected`, `IncStart never overlaps another op in any trace`), target
  `{:interleaving, action}`, allow-listed with
  `allow_untested: [interleavings: […]]`. `AshQuint.Sensitivity.check/3`'s
  result has `never_overlap`; `AshQuint.Sensitivity.overlaps/1` tells
  which ops of a report overlap another.
- `AshQuint.Case` tags concurrent traces' replays `quint_concurrent: true`,
  takes `traces: :all | :sequential | :concurrent` to split one model's
  traces between two modules, and `replay:` for the replay's timeouts.
- Ash and databases in concurrent replays:
  - `AshQuint.Ash.Gate`, an Ash change (`change {AshQuint.Ash.Gate, at:
    :after_read}`) that gates an action: in a `before_action` hook, or
    while the changeset is built in an atomic action.
  - `AshQuint.Gate.Telemetry.attach/2` and `detach/1`: gates at telemetry
    events (Ecto queries, Ash action spans), named `{:query, n}` by
    default, that gate only the ops of the replay that attached them.
    The replay detaches them when it ends, after `finish/2`, also when
    the adapter raises. `telemetry` is an optional dependency; the module
    is compiled when it is present. `AshQuint.Gate.current_replay/0` is the running replay.
  - An optional adapter callback, `blocked?(ctx, op_info)`, polled every
    10 ms while the replay settles: an op it says is blocked settles
    without waiting out the settle timeout. A call records what it may
    wait on with `AshQuint.Gate.put_info/2`. For Postgres,
    `AshQuint.Ash.pg_backend_pid/1` and `AshQuint.Ash.pg_blocked?/2`
    (`pg_blocking_pids`).
  - Op tasks get the test process's Ash tracer span context
    (`AshQuint.Ash.transfer_context/1`).
  - The README's "Databases" covers placing gates, the Ecto sandbox's
    shared mode and real connections (which races inside a transaction
    need), cleanup and blocked ops. ash_quint's own tests replay the race
    example over Postgres too (`mix test --only postgres`).

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
