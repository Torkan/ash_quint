# ash_quint Spec

**Status:** Draft
**Date:** 2026-11-02

## Overview

ash_quint replays the traces of a Quint model against the real system in ExUnit, so that a project can show that its implementation behaves like the model it specified. The system is the implementation of the model. The replay runs each model step through the matching Ash action and asserts, after every step, that the outcome and the state the step covers match the model. It covers three kinds of trace: random runs, witnesses and `run` scenarios. The aim is higher confidence that the implementation is logically correct, with no hand-copied scenario tests that drift from the model.

It generalizes the trace replay that ash_magistrate built by hand for its f1 slice. That replay fits into a spec → plan → exec workflow:

- **spec:** the Quint model and its scenarios;
- **planning:** may extend the model and the scenarios, and maps the model to the code;
- **exec:** writes the adapter and replays every trace as a test.

## Origins

- **ash_magistrate's f1 setup** (`~/src/ash_magistrate`):
  - `bin/f1-traces` pins Quint 0.33.0 and a seed, makes random and witness traces with `--mbt`, strips timestamps and commits the files;
  - `test/support/f1/itf.ex` is a 32-line decoder;
  - `test/ash_magistrate/f1/f1_trace_test.exs` is the replay loop, with a hand-written action mapper and projection;
  - `Driver`, `Snapshot`, `Step` and `Invariants` do the observation;
  - the model keeps a `last` observation variable, so traces carry the outcome.
- **ash_events' temporal work** (`agent-plans/2026-11-02-temporal-resources` in ash_events):
  - the model's 11 `run` scenarios were copied into Elixir by hand (T1–T11), with no ITF;
  - its writes take two model steps (`w` then `ok`) for one Ash call, so model steps and system calls don't line up one to one.
- **quint_connect 0.3.0 on Hex** (Apache-2.0), the Elixir sibling of the Quint team's Rust `quint-connect`:
  - what it has: a `Driver` behaviour, ITF decoding, replay of committed traces (`trace_paths:`), a custom action record (`nondet_path:`) and seed reproduction;
  - what it lacks (D2):
    - its comparison is exact over the whole state, with no mapping of the expected side;
    - every state is one driver step, compared every time;
    - module-qualified variable names in `quint test` traces aren't stripped;
    - there's no outcome concept, no invariant hooks or sensitivity check, no fixture generator with a drift check, and no Ash helpers;
    - it requires Elixir ~> 1.19.

  ash_quint adopts its model conventions (D3) so a model works with both.
- **Other Hex packages** (victoria, itf, apalachex, tla_connect) target Apalache or TLA+ traces, not Quint.

## Goals

- **One trace format for all three sources.** A model that follows the convention (D3) replays its random, witness and scenario traces through the same adapter, unchanged.
- **Each project writes only an adapter.** It maps model names to real values and model actions to Ash calls, and projects the system state into the model's shape. The rest comes from ash_quint: decoding, the replay loop, assertions, failure messages, test generation and trace generation.
- **Model steps and system calls don't have to line up one to one.** A model step can be held until a later step runs the system call (`:pending`), or be model-only (`:skip`).
- **Failures are actionable.** Each one names the trace, the step index, the action and the seed, and shows a per-key diff and every failed invariant.
- **Traces are committed and reproducible.** `mix ash_quint.gen` regenerates them byte for byte with a pinned Quint and seed. `--check` reports drift.
- **Stale traces fail normal CI without Quint.** The ExUnit case compares the manifest's model hashes with the model files.
- **Passing replays are shown to mean something.** The sensitivity check perturbs expectations and drops system calls, and fails if any mutant survives.
- **The core has no Ash dependency.** Ash is optional and needed only for `AshQuint.Ash`.
- **It runs on Elixir ~> 1.15,** ash_events' floor.

## Non-Goals

- Concurrent replay (interleaved transactions on separate connections). Concurrent traces are refused with a clear message; replaying them is a later spec, built on ash_magistrate's lock protocol and ash_events' commit ordering (D5).
- An Elixir port of the model, or StreamData properties against one (D6).
- A Spark DSL for adapters (D4).
- Generating traces at test time, or running Quint in normal CI (D7).
- `quint verify`, Apalache or TLA+ traces.
- Hooking into `mix ash.codegen` (D8).
- Migrating ash_magistrate or ash_events to ash_quint. Each is its own follow-up.

## Decisions

- **D1 (one package, generic core).** A single package, `ash_quint`. Its core (`ITF`, `Trace`, `Step`, `Adapter`, `Replay`, `Names`, `Case`, `Sensitivity` and the Mix task) doesn't depend on Ash. `AshQuint.Ash` holds the Ash helpers, and Ash is an `optional: true` dependency.
- **D2 (standalone, not built on quint_connect).** The gaps that matter (mapped and partial comparison, carried steps, outcomes) sit at the heart of quint_connect's replay loop. Depending on it would mean bypassing its comparison and taking on its Elixir 1.19 floor. Once ash_quint has proven the design on two adapters, its non-Ash parts can be offered upstream.
- **D3 (the model convention follows quint_connect).** The model keeps a `lastAction` variable of a sum type, with the action as the tag and its picks as the value, and optionally a `lastResult` variable. The replay reads both from the model's own state, not from `--mbt` metadata, because `quint test` doesn't support `--mbt`. That was verified with Quint 0.33.0: `Unknown argument: mbt`.
- **D4 (a behaviour, not a DSL).** The adapter is a behaviour module. Real mappings aren't one to one:
  - ash_events' temporal model takes two model steps for one write, and its destroy first reads the record at its `as_of`;
  - ash_magistrate's `batchApprove` sorts and maps its picked ids, and its `unapprove` is checked by the signals it emits;
  - projections are custom SQL or reads across several resources.

  A DSL would need escape hatches for exactly these parts. It can be added later as a layer that compiles to the behaviour, once three or more adapters show what they have in common.
- **D5 (sequential only).** Replay holds at most one pending step. A second `:pending` while one is open, or a trace that ends with one open, is refused. Replaying concurrency needs pause points inside the code under test, which only each app can place, and Postgres decides some orders itself (who gets a lock after a wait, which transaction is the deadlock victim).
- **D6 (the system is the implementation).** Replay compares the system with the Quint traces, so Quint is the only oracle. No Elixir port of the model, and no pluggable expected-state source.
- **D7 (committed traces).** Traces are generated by a Mix task and committed, as ash_magistrate does, so CI needs no Node or Quint. Drift is caught twice: by `mix ash_quint.gen --check`, which needs Quint, and by the model-hash check in the ExUnit case, which doesn't.
- **D8 (`mix ash_quint.gen`, standalone).** The task is `mix ash_quint.gen`, with the flags `mix ash.codegen` uses: `--check` exits 1 if anything would change, and `--dry-run` reports what would change without writing. The name isn't `ash_quint.codegen`, because "codegen" in Ash means the `mix ash.codegen` mechanism, which this task deliberately stays out of. That task finds every module that implements `Spark.Dsl.Extension` in the app and in each dependency that depends on `ash` or `spark` (`Ash.Mix.Tasks.Helpers.extensions!/2`, `Ash.Info.defined_extensions/1`), then calls `codegen/1` on each one that exports it, as `AshPostgres.DataLayer.codegen/1` does to run `ash_postgres.generate_migrations`. Hooking in would make every `mix ash.codegen`, and every CI `mix ash.codegen --check`, need Quint, which committing the traces is meant to avoid. ash_quint defines no Spark extension (D4), so it isn't found, and as a test-only dependency it isn't loaded in dev anyway.
- **D9 (the sensitivity check needs no changes to the app).** Mutants are made in the replay itself: perturbed expectations and dropped system calls. An app doesn't have to build in deliberate bugs.

## Architecture

| Module | Responsibility | Ash |
|---|---|---|
| `AshQuint.ITF` | Decodes an `.itf.json` file into `%AshQuint.Trace{}`, stripping module qualifiers from variable names | no |
| `AshQuint.Trace` | A struct: name, source, path, variables, decoded states | no |
| `AshQuint.Step` | One replayable step built from a state: index, action, picks, result, state | no |
| `AshQuint.Adapter` | The behaviour each model's adapter implements | no |
| `AshQuint.Replay` | Runs a trace through an adapter: steps, assertions, failure messages | no |
| `AshQuint.Names` | Fresh real values for model names, per trace | no |
| `AshQuint.Case` | An ExUnit template: one test per trace in the manifest, the staleness check, the optional sensitivity test | no |
| `AshQuint.Sensitivity` | The mutation check: perturbed expectations and dropped calls | no |
| `AshQuint.Config` | Loads and validates `ash_quint.exs` | no |
| `AshQuint.Manifest` | Reads and writes `manifest.json` | no |
| `Mix.Tasks.AshQuint.Gen` | Generates traces and the manifest; `--check`, `--dry-run` | no |
| `AshQuint.Ash` | Classifies outcomes and snapshots resources and SQL rows | yes |

Dependencies: `jason`, plus `ash ~> 3.0` (optional). Elixir ~> 1.15. MIT license.

## Data Flow

```
model.qnt / model-tests.qnt
  │  mix ash_quint.gen  (pinned Quint via npx or quint_cmd; seed from ash_quint.exs)
  ▼
test/fixtures/quint/<model>/{random_N, witness_<name>, scenario_<name>}.itf.json + manifest.json   (committed)
  │  use AshQuint.Case, model: :<model>, adapter: A   (compile time: manifest → one test per trace)
  ▼
test "<source> <name>" → AshQuint.Replay.run!(A, trace)
  │  for each state after the initial one:
  │    Step.from_state → A.step(ctx, step) → {:ok, result, ctx} | {:pending, ctx} | {:skip, ctx}
  │    :ok   → assert outcome (when lastResult present), then compare projection, run invariants
  │    :skip → compare projection, run invariants
  │    :pending → hold (at most one); compare nothing
  ▼
pass, or an ExUnit failure naming trace, step, action, seed, the diff and failed invariants
```

## Key Interfaces / Data Shapes

### The model convention

```quint
type Action = Init | Create({ rec: int, plan: int, asOf: AsOf }) | Commit(int) | Destroy({ rec: int, asOf: AsOf })
type Result = Accepted | Rejected(str)

var lastAction: Action   // required; set by every action, including init (Init)
var lastResult: Result   // optional; when present, the replay asserts each system call's outcome
```

- The paths are configurable per model: `action_path` defaults to `["lastAction"]`, and `result_path` to `["lastResult"]`. A path that is absent from the trace makes the step's result `nil`, and the outcome isn't asserted.
- The value of a variant is its picks. A record becomes the `nondet_picks` map. Any other value, such as `Commit(1)`, becomes `%{"value" => 1}`, and a unit value (`Init`) becomes `%{}`.
- Model values stay small and finite: integers, strings and variants. The adapter maps them to real values.
- The initial state (index 0) isn't replayed. Its `lastAction` must be `Init`, or the model may name it otherwise via `init_action`.

### Trace and Step

```elixir
%AshQuint.Trace{
  name: "backdatedCreateTest",          # from the manifest
  source: :random | :witness | :scenario,
  path: "test/fixtures/quint/temporal/scenario_backdatedCreateTest.itf.json",
  seed: 20261102,
  vars: ["clock", "live", "log", ...],  # module qualifiers stripped: "tests::model::live" → "live"
  states: [%{"live" => ..., ...}, ...]  # decoded, #meta dropped
}

%AshQuint.Step{
  index: 3,
  action_taken: "Create",
  nondet_picks: %{"rec" => 1, "plan" => 1, "asOf" => {:variant, "Instant", 0}},
  result: :accepted | {:rejected, "code"} | nil,
  state: %{"live" => ..., "log" => ...}  # without the action and result variables
}
```

What the ITF decoder produces: `#map` → map, `#set` → MapSet, `#tup` → tuple, `#bigint` → integer, a variant (`tag` and `value`) → `{:variant, tag, value}` (unit → `{}`). Records stay maps with string keys, and lists stay lists. No atoms are created. When two qualified names strip to the same name, decoding fails rather than picking one.

### Adapter

```elixir
defmodule AshQuint.Adapter do
  @type ctx :: term()
  @callback init(AshQuint.Trace.t(), opts :: keyword()) :: {:ok, ctx}
  @callback step(ctx, AshQuint.Step.t()) ::
              {:ok, result :: term(), ctx}   # ran a system call
              | {:pending, ctx}              # no system call yet; a later step completes it
              | {:skip, ctx}                 # model-only step; compare state, no outcome
  @callback project(ctx) :: map()            # system state, keyed by the model variables it covers
  @callback expected(ctx, AshQuint.Step.t()) :: map()
  @callback outcome(result :: term()) :: :accepted | {:rejected, String.t()} | {:failed, String.t()}
  @callback invariants() :: [{atom(), (projected :: map(), ctx -> :ok | {:error, String.t()})}]
  @optional_callbacks expected: 2, outcome: 1, invariants: 0
end
```

`use AshQuint.Adapter` gives these defaults:
- `expected/2` is `Map.take(step.state, Map.keys(projected))`, for models whose values are already real;
- `outcome/1` is `AshQuint.Ash.outcome/1` when Ash is loaded. Without Ash, `{:ok, _}` counts as accepted and anything else as `{:failed, inspect(other)}`;
- `invariants/0` returns `[]`.

The comparison covers exactly the keys `project/1` returns. `expected/2` must return the same keys, and a missing key is a failure.

Example: a step for ash_events' temporal model, where a write takes two model steps.

```elixir
def step(ctx, %Step{action_taken: "Create", nondet_picks: picks}), do: {:pending, %{ctx | pending: {:create, picks}}}

def step(%{pending: {:create, picks}} = ctx, %Step{action_taken: "Commit"}) do
  result =
    TrackedSubscription
    |> Ash.Changeset.for_create(:create, %{plan: plan(picks)}, as_of: time(ctx, picks["asOf"]), actor: ctx.actor)
    |> Ash.create()

  {:ok, result, %{ctx | pending: nil}}
end
```

### Names

```elixir
{value, ctx} = AshQuint.Names.fetch(ctx, :rec, 1)              # a fresh UUID the first time (rec, 1) is seen, the same one after
{value, ctx} = AshQuint.Names.fetch(ctx, :rec, 1, &my_gen/0)   # a custom generator
AshQuint.Names.reverse(ctx, :rec, uuid)                         # → 1, for projections keyed by model name
```

The names live under the `:ash_quint_names` key of a map `ctx`, so an adapter's `ctx` must be a map.

### Ash helpers

```elixir
AshQuint.Ash.outcome(result, codes: %{MyApp.Errors.Rejected => &(&1.code), Ash.Error.Changes.StaleRecord => "stale"})
# {:ok, _} → :accepted
# {:error, %Ash.Error.Invalid{errors: [e]}} where codes matches e's module → {:rejected, code}
# anything else → {:failed, Exception.message(error)}

AshQuint.Ash.read_map(resource, key: :id, fields: [:plan, :state], read_opts: [tenant: t, authorize?: false])
# → %{id => %{plan: ..., state: ...}}

AshQuint.Ash.sql_rows(repo, sql, params)
# → [%{"column" => value}], for state that Ash doesn't read one row per version (temporal versions)
```

### Config: `ash_quint.exs`

```elixir
[
  quint: "0.33.0",                                   # required; the pinned Quint version
  quint_cmd: ["npx", "--yes", "@informalsystems/quint@{version}"],   # default; e.g. ["mise", "exec", "npm:@informalsystems/quint@{version}", "--", "quint"]
  models: [
    temporal: [
      model: "test/quint/temporal/model.qnt",        # required
      tests: "test/quint/temporal/model-tests.qnt",  # required when scenarios is set
      out: "test/fixtures/quint/temporal",           # required
      seed: 20261102,                                # required
      action_path: ["lastAction"],                   # default
      result_path: ["lastResult"],                   # default
      init_action: "Init",                           # default
      random: [main: "focusSequential", n_traces: 20, max_steps: 12, max_samples: 200],
      witnesses: [main: "spec", names: ~w(witUpsertIntoGap witDestroyTrims), max_steps: 12, max_samples: 50_000],
      scenarios: [main: "tests", match: "Test$"]
    ]
  ]
]
```

At least one of `random`, `witnesses` and `scenarios` must be set. Unknown keys are errors.

### Manifest: `<out>/manifest.json`

```json
{
  "ash_quint": 1,
  "quint": "0.33.0",
  "seed": 20261102,
  "models": { "test/quint/temporal/model.qnt": "sha256:…", "test/quint/temporal/model-tests.qnt": "sha256:…" },
  "traces": [
    { "file": "scenario_backdatedCreateTest.itf.json", "source": "scenario", "name": "backdatedCreateTest",
      "steps": 3, "actions": { "Create": 1, "Commit": 1 } }
  ]
}
```

The output is deterministic: keys sorted, traces sorted by file name, and no timestamps.

### Mix task

```
mix ash_quint.gen [model ...] [--check] [--dry-run]
```

- Runs once per configured model, or for the models named.
  - **random:** `quint run <model> --main=<main> --seed=<seed> --max-steps --max-samples --n-traces --out-itf=<tmp>/random_{seq}.itf.json`.
  - **witness:** for each name, `quint run <model> --main=<main> --seed=<seed> --max-steps --max-samples --invariant="not(<name>)" --out-itf=<tmp>/witness_<name>.itf.json`. A non-zero exit with the file written means the witness was reached.
  - **scenario:** `quint test <tests> --main=<main> --match=<match> --out-itf=<tmp>/scenario_{test}_{seq}.itf.json`, then renamed to `scenario_<test>.itf.json`.
- Normalizes every file: removes `#meta.description` and `#meta.timestamp`, and keeps all other content.
- Without flags, it replaces `<out>` with the new files and the manifest.
- `--dry-run` prints which files would be added, changed or removed.
- `--check` exits 1 if anything would change.

### ExUnit case

```elixir
use AshQuint.Case,
  model: :temporal,                  # a key in ash_quint.exs
  adapter: MyApp.TemporalTrace,
  adapter_opts: [],                  # passed to init/2
  sensitivity: false                 # true adds the sensitivity test
```

- Use it after the project's own case template (`use MyApp.DataCase`), which keeps the DB sandbox and `async`.
- At compile time it reads `ash_quint.exs` and the manifest, and defines one test per trace (`"scenario backdatedCreateTest"`, `"witness witUpsertIntoGap"`, `"random 7"`), tagged `quint: <source>` and `quint_model: <model>`.
- The config, the manifest, every trace and every model file are `@external_resource`s.
- It also defines `"traces for <model> are current"`, which fails if a model file's hash differs from the manifest.

## Replay semantics

For each state at index ≥ 1, in order:

1. **Build the step.** Strip the module paths, take the action from `action_path` and the result from `result_path`, and put the remaining variables in `state`.
2. **Call `adapter.step(ctx, step)`.** A missing clause is reported as an error (see Error Handling).
3. **Handle the return value:**
   - **`{:pending, ctx}`:** if a pending step is already open, fail (D5). Otherwise mark one as open. Compare nothing.
   - **`{:ok, result, ctx}`:** close any open pending step. If `step.result` isn't nil, assert that `outcome(result) == step.result`. `{:failed, msg}` always fails, whether or not a result is expected.
   - **`{:skip, ctx}`:** check that no pending step is open (D5), and assert no outcome.
4. **After `:ok` or `:skip`:** compute `projected = project(ctx)` and assert that it equals `expected(ctx, step)` on the keys of `projected`. Then run every invariant on `projected`. All failures of the step (diff and invariants) are collected before failing.
5. **At the end of the trace:** fail if a pending step is still open.

## Sensitivity check

`AshQuint.Sensitivity.check(adapter, traces, opts)` replays mutants and returns the ones that survived. `use AshQuint.Case, sensitivity: true` asserts that the list is empty. There are two kinds of mutant (D9):

- **Perturbed expectation.** For each projected key, the first synced step in any trace where the expected value differs from the previous synced step's has that value replaced with a sentinel (`{:ash_quint_mutated, key}`). The replay must fail at that step on that key. A key whose expected value never changes in any trace is reported as untested.
- **Dropped call.** For each action name that returned `{:ok, …}` in any trace, the first such step is replayed as `{:skip, ctx}`, with no system call. The replay must fail at that step or a later one, on the state, the outcome, or a raised error. If the replay passes, the mutant has survived.

The mutants run in the test's sandbox, one after another, each on fresh `Names`. A mutant that crashes counts as detected.

## Error Handling

| Failure | Behaviour |
|---|---|
| Malformed JSON, an unknown ITF form (`#unserializable`), duplicate stripped names | `AshQuint.ITF.Error` with the file and the JSON path |
| `lastAction` missing, or not a variant | Test failure naming the path, the trace and the step |
| No `step/2` clause for an action | "adapter A has no step/2 clause for `Commit` (random_3 step 4)", instead of a FunctionClauseError |
| `step/2` returns something other than the three shapes | Test failure showing the value |
| Second `:pending`, `:skip` with a pending step open, or a trace ending with one open | "interleaved trace: concurrent replay is out of scope for ash_quint v1 (random_3 step 5)" |
| Outcome mismatch | Expected and actual outcome, plus the `{:failed, message}` text |
| State mismatch or failed invariants | The keys that differ, with expected and actual values per key (`inspect(pretty: true)`), and every failed invariant with its message |
| `expected/2` missing a projected key | Test failure naming the key |
| Stale traces | `"traces for :temporal are stale: <file> changed; run mix ash_quint.gen temporal"` |
| A model missing from `ash_quint.exs`, a manifest missing or without traces | Compile error from `AshQuint.Case` |
| Invalid `ash_quint.exs` | `Mix.raise`, naming the key |
| Quint not runnable, a scenario failing in Quint, a witness not reached, a random run violating an invariant | `mix ash_quint.gen` raises with Quint's output and writes nothing |

Every replay failure message starts with `<model> <source> <name>, step <index> (<action>), seed <seed>`.

## Testing Strategy

- **ITF decoding:**
  - fixtures made with real Quint 0.33.0 and committed: a `quint run` trace and a `quint test` trace with qualified names (`tests::model::live`);
  - every value form and the variant shapes (unit, record, scalar);
  - duplicate stripped names, unknown forms, and a check that no atoms are created.
- **Step building:** the action and its picks for each variant shape; absent `lastResult` gives `nil`; `Accepted` and `Rejected(code)` map to outcomes; custom paths work.
- **The replay loop,** against an in-memory toy adapter (a counter or a small bank, held in the adapter's `ctx`), with one test each for:
  - the passing path;
  - outcome mismatches, state mismatches, a missing expected key and failed invariants, each asserting the exact message;
  - `:pending` then `:ok`;
  - a second `:pending`, and a trace ending pending;
  - `:skip`;
  - a missing clause and a bad return value.
- **Names:** fresh values per trace, stable within one, `reverse/3`, and a custom generator.
- **The Ash helpers,** with an ETS-backed test resource: `outcome/2` for accepted, mapped rejections and unmapped errors; `read_map/2`. `sql_rows/3` is covered only by a Postgres-tagged test, excluded by default (the first adopter, ash_events, exercises it).
- **Case:**
  - a test module built from a committed fixture manifest generates the expected test names and tags;
  - a changed model hash fails the staleness test;
  - a missing manifest or model is a compile error, tested with `Code.compile_string`.
- **The sensitivity check:**
  - a full adapter yields no surviving mutants;
  - an adapter whose projection leaves out a changing variable has its perturbation detected but its dropped call surviving;
  - a variable that never changes is reported as untested.
- **The Mix task:**
  - config validation and manifest determinism, tested with no Quint;
  - generation, `--check` and `--dry-run` against `priv/examples/counter`, tagged `:quint` and excluded by default, run in CI in a separate job with Node.
- **End to end:**
  - `priv/examples/counter/model.qnt` and `model-tests.qnt` follow the convention;
  - their committed traces replay through `AshQuint.Case` in the default suite.
- **Adoption check:** ash_events' temporal model replays through an ash_quint adapter, and its random, witness and scenario traces pass. This is a separate follow-up in ash_events, but it's the acceptance test for v1.
- **Checks:** `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`, `mix docs`, `mix test`.

## Formal Model

No model. The replay loop's own state is a single pending slot and a synced flag, too small for a model to add confidence. ash_quint's correctness is shown by its tests and by replaying ash_events' and ash_magistrate's models.

## Open Questions

- **Package docs for the skills.** The spec, planning and exec skills (tgk plugin) should name ash_quint's convention and the adapter task. That's a change to the skills, done once ash_quint v1 exists, not part of this package.
- **Where model files live in a consuming project.** This spec uses `test/quint/<model>/`. ash_magistrate uses `test/fixtures/f1_model/`, and ash_events keeps its model in `agent-plans/`, which is git-excluded locally, so the model would have to be copied into the repo. The convention is up to each project, since `ash_quint.exs` takes any path. The ash_events adoption has to decide where its model lives.
