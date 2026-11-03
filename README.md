# AshQuint

Replay the traces of a [Quint](https://quint-lang.org) model against the real
system in ExUnit. ash_quint decodes Quint ITF traces, runs each model step
through a per-model adapter (with helpers for Ash resources), and checks the
outcome, the state the step covers and the model's invariants after every
step. Traces are generated with a pinned Quint by `mix ash_quint.gen` and
committed, so the test suite needs neither Node nor Quint.

How it fits together:

1. You write a Quint model that follows a small convention (it records each
   step's action and result in variables).
2. `mix ash_quint.gen` runs Quint (random runs, witnesses, scenario tests)
   and writes the traces and a manifest into your repo. You commit them.
3. `use AshQuint.Case` turns every committed trace into an ExUnit test that
   replays it through your adapter, plus a test that fails when the model
   changed and the traces are stale, and optionally a sensitivity test that
   checks the replays would catch a broken system.

The worked example is the `counter` model: the model and its traces are in
[`priv/examples/counter`](https://github.com/Torkan/ash_quint/tree/main/priv/examples/counter)
(shipped in the package), and its adapter, over an Ash resource, is
[`test/support/counter_adapter.ex`](https://github.com/Torkan/ash_quint/blob/main/test/support/counter_adapter.ex).

## Installation

ash_quint needs Elixir 1.17 or later. Add it to your test dependencies in
`mix.exs`:

```elixir
def deps do
  [
    {:ash_quint, "~> 0.1", only: :test}
  ]
end
```

Ash is optional: `AshQuint.Ash` and the Ash-aware default `outcome/1` are
there only when your project depends on `ash`.

Since ash_quint is a test-only dependency, its Mix task exists only under
`MIX_ENV=test`. Either run it as `MIX_ENV=test mix ash_quint.gen`, or make
`test` its preferred environment in `mix.exs`:

```elixir
def cli do
  [preferred_envs: ["ash_quint.gen": :test]]
end
```

Generating traces needs Node (for `npx`) or another way to run Quint; see
`quint_cmd` below. Running the tests needs neither.

## The model convention

ash_quint follows quint_connect's convention: the model records, in its own
state, which action each step took and what it returned.

```quint
type Action = Init | Inc({ ctr: str, by: int }) | Reset(str) | Peek(str)
type Result = Accepted | Rejected(str)

var lastAction: Action   // required; set by every action, init included
var lastResult: Result   // optional; when present, outcomes are asserted
```

- **`lastAction`** is a sum type. The tag is the action's name, and the value
  holds its nondeterministic picks. A record value becomes the step's
  `nondet_picks` map (`%{"ctr" => "c1", "by" => 2}`); any other value `v`
  becomes `%{"value" => v}` (`Reset("c1")` → `%{"value" => "c1"}`); a unit
  value (`Init`) becomes `%{}`. A Quint `Map` decodes like a record, so
  `Act(m)` with a `Map` value gives its entries as the picks; wrap it in a
  record (`Act({ m: m })`) to keep it whole.
- **`lastResult`**, when the model has it, is `Accepted` or
  `Rejected(code)`. The replay asserts that the system's outcome matches.
  Without it, outcomes aren't asserted.
- **`init`** sets `lastAction` to `Init`. The initial state isn't replayed;
  the adapter's `init/2` sets up the system instead. Then `project/1` and
  `expected/2` are called once on the initial state (step 0, action `Init`)
  to record the starting values the sensitivity check compares with; nothing
  is asserted there, but an exception fails the replay at step 0.
- Every other variable is model state, which the adapter's projection is
  compared with.
- Keep model values small and finite (integers, strings, variants); the
  adapter maps them to real values, for example with `AshQuint.Names`.

The variable names and the initial action's name are configurable
(`action_path`, `result_path`, `init_action`).

Some things to know about Quint 0.33.1 when writing a model:

- `set`, `get` and `next` are reserved and can't name a variable or action
  (QNT101). The counter uses `inc`, `reset` and `peek`.
- Model integers must fit in a signed 64-bit integer: the Rust evaluator
  rejects anything larger (QNT600). Quint writes integers with |n| ≥ 10^15
  as bignumber.js objects rather than `#bigint`; ash_quint decodes both to
  integers.
- `quint run` looks for actions named `init` and `step`. Name them
  otherwise and set `init:` and `step:` in the config.
- Variable names are qualified (`tests::model::count`) when a test module
  imports the model as an instance; ash_quint strips the qualifiers.

Witnesses are boolean `val`s that become true in a state worth reaching
(`val witOverLimit = lastResult == Rejected("over_limit")`). Scenarios are
`run` tests in a separate tests module. See
[`model.qnt`](https://github.com/Torkan/ash_quint/blob/main/priv/examples/counter/model.qnt)
and
[`model-tests.qnt`](https://github.com/Torkan/ash_quint/blob/main/priv/examples/counter/model-tests.qnt).

## Configuration: `ash_quint.exs`

`ash_quint.exs`, at the project root, evaluates to a keyword list. Every
key, with its default:

```elixir
[
  # Required: the pinned Quint version.
  quint: "0.33.1",
  # The command that runs Quint; {version} is replaced by `quint`.
  # Another way: ["mise", "exec", "npm:@informalsystems/quint@{version}", "--", "quint"]
  quint_cmd: ["npx", "--yes", "@informalsystems/quint@{version}"],
  # Base directory of each model's model and tests files.
  model_dir: "test/quint",
  # Base directory of each model's traces.
  fixture_dir: "test/fixtures/quint",
  # :skip when model files aren't committed (see "The test case").
  on_missing_model: :fail,
  models: [
    counter: [
      model: "test/quint/counter/model.qnt",        # <model_dir>/<name>/model.qnt
      tests: "test/quint/counter/model-tests.qnt",  # <model_dir>/<name>/model-tests.qnt
      out: "test/fixtures/quint/counter",           # <fixture_dir>/<name>
      on_missing_model: :fail,                      # the top-level setting
      seed: 20_261_102,                             # required
      action_path: ["lastAction"],
      result_path: ["lastResult"],
      init_action: "Init",
      # At least one of random, witnesses and scenarios.
      random: [
        main: "counter",       # required: the module to run
        init: "init",          # optional, Quint's default
        step: "step",          # optional, Quint's default
        n_traces: 20,          # optional, Quint's default
        max_steps: 12,         # optional, Quint's default
        max_samples: 200       # optional, Quint's default
      ],
      witnesses: [
        main: "counter",       # required
        names: ["witOverLimit", "witResetAfterInc"],  # required
        init: "init",          # optional
        step: "step",          # optional
        max_steps: 12,         # optional
        max_samples: 50_000    # optional
      ],
      scenarios: [
        main: "tests",         # required: the tests module
        match: "Test$"         # optional: which runs
      ]
    ]
  ]
]
```

- Paths are relative to the project root and must stay inside it, the
  defaults built from a model's name included. They can point anywhere in
  it, including a directory that isn't committed (see `on_missing_model`).
  The manifest records model paths as configured.
- Each model's `out` must be its own directory: not the project root, and
  not another model's `out`.
- `tests` is used only when `scenarios` is set.
- Unknown keys, duplicate keys and wrongly typed values are errors that name
  the key, e.g. `ash_quint.exs: unknown key models.counter.random.invariants`.

## Generating traces: `mix ash_quint.gen`

```sh
mix ash_quint.gen [model ...] [--check] [--dry-run]
```

For every configured model (or only those named), from the project root:

- **random:** `quint run <model> --main=<main> --seed=<seed> [--init=…]
  [--step=…] [--max-steps=…] [--max-samples=…] [--n-traces=…]
  --out-itf=…/random_{seq}.itf.json`, named `random 0`, `random 1`, …
  Any non-zero exit is an error.
- **witnesses:** for each name, `quint run … --invariant=not(<name>)
  --out-itf=…/witness_<name>.itf.json`. The witness is reached when Quint
  reports the invariant violated; if it isn't, raise `max_samples` or
  `max_steps`.
- **scenarios:** `quint test <tests> --main=<main> [--match=…] --seed=<seed>
  --out-itf=…/scenario_{test}_{seq}.itf.json`, each renamed to
  `scenario_<test>.itf.json`. Any failing test is an error.

The same seed is passed to `quint test` too, so scenarios that use `nondet`
regenerate byte for byte. Each file is normalized (Quint's `description` and
`timestamp` are removed from `#meta`; everything else is kept as written),
and `<out>/manifest.json` records the Quint version, the seed, a hash of
each model file, and each trace's name, source, step count and actions.

- Without flags, the task replaces the `*.itf.json` files and
  `manifest.json` in each model's `out` directory and leaves other files
  there alone. Nothing is written unless every model generates.
- `--dry-run` prints the files that would be added, changed or removed.
- `--check` prints the same and exits with status 1 if anything would
  change; with no changes it prints `ash_quint.gen: traces are current`.

Commit the traces and the manifest.

## Writing an adapter

An adapter implements `AshQuint.Adapter` for one model. The counter's:

```elixir
defmodule MyApp.CounterTrace do
  use AshQuint.Adapter

  alias AshQuint.{Names, Step}

  @impl true
  def init(_trace, _opts), do: {:ok, %{ids: MapSet.new()}}

  @impl true
  def step(ctx, %Step{action_taken: "Inc", nondet_picks: %{"ctr" => ctr, "by" => by}}) do
    {counter, ctx} = counter(ctx, ctr)
    {:ok, Ash.update(counter, %{by: by}, action: :inc), ctx}
  end

  def step(ctx, %Step{action_taken: "Reset", nondet_picks: %{"value" => ctr}}) do
    {counter, ctx} = counter(ctx, ctr)
    {:ok, Ash.update(counter, %{}, action: :reset), ctx}
  end

  def step(ctx, %Step{action_taken: "Peek"}), do: {:skip, ctx}

  @impl true
  def outcome(result), do: AshQuint.Ash.outcome(result, codes: %{MyApp.Rejected => & &1.code})

  @impl true
  def project(ctx) do
    rows =
      MyApp.Counter
      |> AshQuint.Ash.read_map(key: :id, fields: [:count, :writes])
      |> Map.take(MapSet.to_list(ctx.ids))
      |> Map.new(fn {id, row} -> {Names.reverse(ctx, :ctr, id), row} end)

    %{
      "counts" => Map.new(rows, fn {ctr, row} -> {ctr, row.count} end),
      "writes" => Map.new(rows, fn {ctr, row} -> {ctr, row.writes} end)
    }
  end

  # counter/2 opens the row named ctr on first use; see the full adapter.
end
```

The full version, with `counter/2` and invariants, is
[`test/support/counter_adapter.ex`](https://github.com/Torkan/ash_quint/blob/main/test/support/counter_adapter.ex).

The callbacks:

- **`init(trace, opts)`** builds a fresh `ctx` for one trace; `opts` is the
  case's `adapter_opts`. Use a map if you use `AshQuint.Names`.
- **`step(ctx, step)`** performs one step, matching on
  `step.action_taken` and `step.nondet_picks`. Return:
  - `{:ok, result, ctx}` after a system call. `outcome(result)` must match
    the model's `lastResult`;
  - `{:pending, ctx}` when the action only starts a call that a later step
    completes (a create that a later commit finishes). Nothing is compared
    until that step returns `{:ok, …}`;
  - `{:skip, ctx}` for a model-only step: the state is compared, no outcome
    is asserted.

  A trace with two pending steps open, a skip while one is pending, or a
  pending step at the end fails: replays are sequential.
- **`project(ctx)`** returns the system's state, keyed by the model
  variables it covers, in the model's terms. Only those keys are compared.
- **`expected(ctx, step)`** (optional) returns the model's value for each
  projected key. The default takes them from `step.state` as they are; define
  it when the model's values need translating.
- **`outcome(result)`** (optional) classifies a call's result as
  `:accepted`, `{:rejected, code}` or `{:failed, message}`. The default is
  `AshQuint.Ash.outcome/1` when Ash is available where the adapter is
  compiled, and otherwise `AshQuint.Adapter.default_outcome/1` (`:ok` and
  `{:ok, _}` are accepted). An adapter that implements the behaviour without
  `use AshQuint.Adapter` gets the same default at run time. Pass `codes:` to
  `AshQuint.Ash.outcome/2` to map your error modules to the model's
  rejection codes.
- **`invariants()`** (optional) lists `{name, fun}` checks run after every
  synced step: `fun.(projected, ctx)` returns `:ok` or `{:error, message}`.
- **`finish(ctx, result)`** (optional) runs exactly once when a replay
  ends, with the latest `ctx`: with `:ok` after the last step's checks, with
  `{:error, failure}` at the first failing step, and, when an adapter
  callback raises, with the `ctx` that callback was given, before the
  exception propagates. Release what `ctx` holds there. Return `:ok`, or
  `{:error, message}` to fail a passing replay at its last step (an
  end-of-trace check, such as a witness reached on the real system); on a
  failing replay the original failure is kept.

Two rules matter in practice:

- **Scope `project/1` to the trace.** The sensitivity check replays every
  trace and mutant one after another in one test, so the database holds the
  rows of earlier replays. Read only what this trace created: a tenant made
  in `init/2`, or the ids it named (the counter keeps them in `ctx.ids`).
  For the same reason, release in `finish/2` whatever a replay holds open
  (processes, transactions, checked-out connections, locks): mutants fail
  partway through, and without `finish/2` what they opened stays alive
  until the test process exits.
- **Transition invariants go through `ctx`.** An invariant sees only the
  projection and `ctx`. One that compares a step with the one before keeps
  what it needs (the rows before the call, say) in `ctx`, from `step/2`.

Helpers:

- `AshQuint.Names` maps the model's small values (`"c1"`, `1`) to real ones
  (UUIDs by default), fresh per trace, and back again for projections.
- `AshQuint.Ash.read_map/2` snapshots a resource as a map keyed by one field;
  `AshQuint.Ash.sql_rows/3` snapshots raw SQL rows, for state Ash doesn't
  read one row per record.

## The test case

```elixir
defmodule MyApp.CounterTraceTest do
  use MyApp.DataCase, async: true

  use AshQuint.Case,
    model: :counter,
    adapter: MyApp.CounterTrace,
    adapter_opts: [],
    sensitivity: true
end
```

Put it after `use ExUnit.Case` or your case template, so the template's
sandbox and `async` apply. At compile time it reads `ash_quint.exs` and the
model's manifest and defines:

- one test per trace, named `"random 0"`, `"witness witOverLimit"` or
  `"scenario incTest"`, tagged `quint: <source>` and `quint_model: <model>`;
- `"traces for counter are current"`, which fails when a model file's hash
  no longer matches the manifest: run `mix ash_quint.gen counter`;
- with `sensitivity:`, `"sensitivity of counter"` (see below).

The config, manifest, traces and model files are external resources, so
the module recompiles when they change. An unknown model, a missing
manifest or one without traces is a compile error.

Select the tests by tag: `mix test --only quint_model:counter`,
`mix test --only quint:witness`.

If your model files aren't committed (they live in an ignored planning
directory, say), set `on_missing_model: :skip`. The staleness test is then
skipped when the model file is missing; the replays still run, since they
need only the committed traces. With the default `:fail`, a missing model
file fails it.

### Failures

Every replay failure names the trace, step, action and seed, and then lists
all of that step's problems:

```
counter random 3, step 4 (Inc), seed 20261102: outcome: expected :accepted, got {:rejected, "over_limit"}
```

The problems are an outcome mismatch, a failed system call
(`{:failed, message}`), a missing `step/2` clause, a bad return value, a
projected key that differs from the model (or has no expected value), a
failing invariant, an interleaved trace, an exception from `project/1`
or `expected/2` on the initial state (at step 0), and an `{:error, message}`
from `finish/2` (at the last step). Other exceptions from the
adapter propagate as they are, without the prefix. That includes a missing
clause in a helper that `step/2` delegates to: only a `FunctionClauseError`
from the adapter's own `step/2` is reported as a missing clause.

## Sensitivity

A replay that passes may not prove much: the projection can miss the state
that matters. `sensitivity: true` adds a test that replays mutants that must
fail:

- **Perturbed expectation.** For each projected key, the first step where
  the model's value changes gets a wrong expected value. The replay must
  fail there, on that key.
- **Dropped call.** For each action that makes system calls, the first call
  that changes the model's state is skipped instead of made. The replay must
  fail at that step or later. A rejected call, or one that changes nothing,
  can't be detected when dropped, so it isn't picked.

The test fails when a mutant survives, and when something is untested:

```
sensitivity of :counter:
perturbed "counts" at random 0 step 3 was not detected
dropped Reset at random 1 step 6 was not detected
key "plans" never changes in any trace
no step of Refresh changes the state
```

An untested key or action usually means a coverage gap: a path no random
run, witness or scenario reaches. Add a witness or scenario for it. For
deliberate constants (setup picked with `nondet` in `init` and never
changed), allow-list them:

```elixir
use AshQuint.Case,
  model: :billing,
  adapter: MyApp.BillingTrace,
  sensitivity: [allow_untested: [keys: ["plans"], actions: ["Refresh"]]]
```

`sensitivity: true` is `[allow_untested: []]`. An allow-listed key or
action that turns out to be tested, or that the check doesn't know, also
fails the test, so the list can't go stale. Actions that only ever return
`{:skip, …}` make no system call and are never checked (the counter's
`Peek`). The `sensitivity:` value must be a literal.

## CI

- The default test suite needs neither Node nor Quint: run `mix test`.
- In a job with Node, run `MIX_ENV=test mix ash_quint.gen --check`. It
  regenerates every model's traces and fails if they differ from the
  committed ones, so a model change without regenerated traces, or a
  change in Quint's output, is caught. It needs the model files, so with
  `on_missing_model: :skip` and models that aren't committed it fails in
  CI; run it where the models are instead, or name only the committed
  models (`mix ash_quint.gen counter --check`).

## Limitations

- Replays are sequential: a trace whose actions interleave (two pending
  steps) is refused.
- `random:` takes no invariants to check; any non-zero exit of
  `quint run` fails generation.
- Model integers are limited to the signed 64-bit range by Quint.

## License

MIT; see `LICENSE`.
