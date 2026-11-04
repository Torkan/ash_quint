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
  Without it, outcomes aren't asserted. A third variant, `Pending`, marks a
  call still in flight (see [Concurrency](#concurrency) below).
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

### Concurrency

A model can let calls overlap: two requests racing on one row, a retry
overlapping a commit. It still takes one action per step, and spells the
overlap out as separate **start** and **completion** actions over an
**operation id**:

```quint
type Action = Init | IncStart({ op: str, by: int }) | IncDone({ op: str })
type Result = Accepted | Rejected(str) | Pending
```

- **Operation ids.** Every action that starts, advances or completes an
  in-flight call has an `op` field in its record value
  (`IncStart({ op: "o1", by: 2 })`, `IncDone({ op: "o1" })`). The model
  holds a small set of ids (`Set("o1", "o2")`). The step's `op` is the id
  (a string); it stays in `nondet_picks` too.
- **`Pending`.** A step that starts or advances a call sets
  `lastResult' = Pending`: the call stays in flight, and no outcome is
  asserted there. A `Pending` step must have an `op`.
- **The completing step's `lastResult`** is the outcome of the call it
  completes. One call completes per step, so one `lastResult` is enough.
- **In-flight bookkeeping is ordinary model state** (`inflight: str -> int`).
  The adapter doesn't project it.
- **Model what the system visibly shows.** The replay compares every
  step's state, starts included, while calls are in flight, so uncommitted
  writes don't belong in projected variables. An invariant that holds only
  when nothing is in flight is wrong here: Quint checks the model's on every
  state too.
- **Interleaving points are a model choice.** `IncStart` and `IncDone` give
  "requested" and "returned"; split the action further (`IncRead`) for more.

The field and variant names are configurable (`op_field`, `pending_result`).
The manifest marks each trace with a call in flight as `"concurrent": true`,
with the most calls in flight at once as `"max_in_flight"`. See the
[`race`](https://github.com/Torkan/ash_quint/blob/main/priv/examples/race/model.qnt)
example: two `Inc`s against a limit, and a scenario where both start before
either returns.

The replay runs each in-flight call in its own process and holds it at
gates while other steps run; see [Concurrent calls](#concurrent-calls) for
the adapter's side.

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
      pending_result: "Pending",                    # see "Concurrency"
      op_field: "op",
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
each model file, and each trace's name, source, step count, actions and,
per action, outcomes (see Coverage below).

- Without flags, the task replaces the `*.itf.json` files and
  `manifest.json` in each model's `out` directory and leaves other files
  there alone. Nothing is written unless every model generates. After
  writing a model it prints the model's coverage table (see below).
- `--dry-run` prints the files that would be added, changed or removed.
- `--check` prints the same and exits with status 1 if anything would
  change; with no changes it prints `ash_quint.gen: traces are current`.

Commit the traces and the manifest.

## Coverage: `mix ash_quint.coverage`

```sh
mix ash_quint.coverage [model ...]
```

prints, for every configured model (or only those named), which outcomes
each action reaches across the committed traces. It reads only
`ash_quint.exs` and the manifests, so it needs neither Node nor Quint. For
the counter example:

```text
counter: 9 traces, 53 steps
  Inc    23  accepted 20  rejected:over_limit 3
  Peek   20  accepted 20
  Reset  10  accepted 10
```

Each row is an action the traces take, with its step count and then each
result it reaches with its count. A result is labelled `accepted` for
`Accepted` and `rejected:<code>` for `Rejected(code)`, so
`Rejected("over_limit")` is `rejected:over_limit`. A step that keeps its
call in flight (see [Concurrency](#concurrency)) is labelled `pending`, and
the step that completes the call counts under its own outcome. For the race
example, where `IncStart` starts and `IncDone` completes:

```text
race: 6 traces, 22 steps
  IncDone   10  accepted 7  rejected:over_limit 3
  IncStart  12  pending 12
```

There are more starts than completions because the `witOverlap` witness
ends with both calls in flight. A label missing from a
row is an outcome no trace reaches, for example a rejection the random
runs never hit: add a witness or a scenario for it. Actions the traces
never take aren't listed (the manifest doesn't know the model's actions),
so compare the rows with the model's `Action` type.

For a model without `lastResult`, the rows have the step counts only. In a
model with results, steps without one show as `no result <n>`.

`mix ash_quint.gen` prints the same table after writing each model, so a
regeneration shows at once what the new traces reach. `--check` and
`--dry-run` print only the file changes.

A manifest written by ash_quint 0.1.0 (format 1) has no outcomes:
replays still work with it, but `mix ash_quint.coverage` asks you to
regenerate it with `MIX_ENV=test mix ash_quint.gen <model>`.

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
    is asserted;
  - `{:start, op, call, ctx}`, `{:advance, op, ctx}` and
    `{:complete, op, ctx}` for calls that stay in flight while other steps
    run: see [Concurrent calls](#concurrent-calls).

  `{:pending, ctx}` is the sequential form: a trace with two pending steps
  open, a skip while one is pending, or a pending step at the end fails.
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

### Concurrent calls

For a model that lets calls overlap (see [Concurrency](#concurrency)), the
adapter starts the real call at the start step and the replay runs it in an
**op task**, a process of its own, while the trace goes on:

```elixir
def step(ctx, %Step{action_taken: "IncStart", nondet_picks: %{"op" => op, "by" => by}}) do
  call = fn -> MyApp.Counter |> Ash.get!(ctx.id) |> Ash.update(%{by: by}, action: :inc) end
  {:start, op, call, ctx}
end

def step(ctx, %Step{action_taken: "IncDone", nondet_picks: %{"op" => op}}),
  do: {:complete, op, ctx}
```

- **`{:start, op, call, ctx}`** runs `call` (no arguments; it makes the
  system call and returns its result) in a new op task. `op` is normally
  `step.op`; it must not already be in flight. The step must be `Pending`
  in the trace.
- **`{:advance, op, ctx}`** releases `op` from its gate and waits until it
  stops at the next one. It is for models that split one call into more
  than two steps (`IncStart`, `IncRead`, `IncDone`). The step must be
  `Pending`.
- **`{:complete, op, ctx}`** releases `op` through every remaining gate,
  waits for its result and checks `outcome(result)` against the step's
  `lastResult`, as for `{:ok, …}`. The step must not be `Pending`.
- `{:ok, …}`, `{:skip, …}` and `{:pending, …}` still run in the test process
  while ops are in flight.

**Gates** are where an op task stops. Put `AshQuint.Gate.checkpoint/1` in the
system's code path, where the race can happen:

```elixir
change fn changeset, _context ->
  count = Ash.Changeset.get_data(changeset, :count)
  AshQuint.Gate.checkpoint(:after_read)
  # …
end
```

Outside an op task it returns `:ok` at once, so it can stay in code that
compiles for test (ash_quint is a test-only dependency: put it behind
`if Mix.env() == :test`, or in a test-only change). Inside one, it waits for
the replay. Processes the call starts with `Task` gate their op too, since
the gate looks up `$callers`. Gate names are your own atoms (or tuples).

**Settling.** After every step, the replay waits until each op in flight is
at a gate or has finished, then compares the state and runs the invariants,
on every step, starts included. An op that does neither within
`settle_timeout` fails the step, unless it was started with
`may_block: true`: then it counts as blocked (on a lock another op holds,
say), and the replay waits for it again after the next release.

Options, as a fifth element (`{:start, op, call, ctx, opts}`) or a fourth
(`{:advance, op, ctx, opts}`):

- `early: :ok` (start only): the call may finish before it reaches a gate.
  Without it that fails: an op that returns at its start step overlapped
  nothing. Its result is held until its completion step either way;
- `may_block: true`: see Settling;
- `at: name`: the gate the op must reach (the first one for a start, the
  next one for an advance); another gate fails the step, naming both.

A synchronous step (`{:ok, …}`) that blocks on something a gated op holds is
released by a watchdog after `step_timeout`: it frees every gated op and
fails the step. A gate that the replay doesn't release within `gate_timeout`
returns anyway and fails the step the replay is on, so a wrong release order
can't hang the test. A trace that ends with ops in flight passes: they are
cancelled unchecked (random traces stop at `max_steps`, often mid-call).
Every op task is stopped before `finish/2` runs, on every path, so
`finish/2` can release what the ops used.

The timeouts, `AshQuint.Replay.run/3` options in milliseconds:
`settle_timeout` (default 500), `step_timeout` (2000), `complete_timeout`
(5000, for a completed op's result) and `gate_timeout` (5000). `AshQuint.Case`
uses the defaults.

The race example's adapter,
[`test/support/race_adapter.ex`](https://github.com/Torkan/ash_quint/blob/main/test/support/race_adapter.ex),
replays every race trace against an ETS resource with an atomic increment;
with its read-modify-write `:inc` action, `raceTest` fails at step 4 on the
lost update. Two things it shows:

- **Make the call do the read.** Fetch the record inside `call`, not in
  `step/2`, so the read happens in the op task, between the gates.
- **Op tasks are other processes.** A `private? true` ETS table is visible
  only to its owner, so concurrent replays need a table that isn't private,
  scoped by the ids the trace names. Database sandboxes allow op tasks
  through `$callers`, but all of them share the test's connection.

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
  `"scenario incTest"`, tagged `quint: <source>` and `quint_model: <model>`,
  and `quint_concurrent: true` when the manifest marks the trace
  concurrent;
- `"traces for counter are current"`, which fails when a model file's hash
  no longer matches the manifest: run `mix ash_quint.gen counter`;
- with `sensitivity:`, `"sensitivity of counter"` (see below).

The config, manifest, traces and model files are external resources, so
the module recompiles when they change. An unknown model, a missing
manifest or one without traces is a compile error.

Select the tests by tag: `mix test --only quint_model:counter`,
`mix test --only quint:witness`.

Concurrent traces run their calls in op tasks, other processes than the
test's. A private ETS table, per-process state or a database sandbox in
manual mode doesn't reach them. `traces: :sequential` or `traces: :concurrent`
splits one model's traces between two modules, so the sequential ones stay
in the async module and the concurrent ones run where op tasks can see the
data:

```elixir
defmodule MyApp.RaceTraceTest do
  use MyApp.DataCase, async: true
  use AshQuint.Case, model: :race, adapter: MyApp.RaceTrace, traces: :sequential
end

defmodule MyApp.RaceConcurrentTraceTest do
  use MyApp.UnboxedCase, async: false

  use AshQuint.Case,
    model: :race,
    adapter: MyApp.RaceTrace,
    traces: :concurrent,
    sensitivity: true,
    replay: [settle_timeout: 1_000]
end
```

`traces:` is `:all` (the default), `:sequential` or `:concurrent`; a
selection with no trace is a compile error. Each module has its own
staleness test, and the sensitivity check runs over its traces only. The
`quint_concurrent` tag selects the concurrent replays across modules:
`mix test --only quint_concurrent`.

`replay:` passes the replay's timeouts (`settle_timeout`, `step_timeout`,
`complete_timeout` and `gate_timeout`, in ms; see "Concurrent calls");
any other key is a compile error.

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
failing invariant, an interleaved trace (overlapping `{:pending, …}`
steps), a model and adapter that disagree on which steps keep a call in
flight, an op's problems (below), an exception from `project/1`
or `expected/2` on the initial state (at step 0), and an `{:error, message}`
from `finish/2` (at the last step). Other exceptions from the
adapter propagate as they are, without the prefix. That includes a missing
clause in a helper that `step/2` delegates to: only a `FunctionClauseError`
from the adapter's own `step/2` is reported as a missing clause.

With calls in flight, the problems include:

```
op "o1" (started at step 1): outcome: expected {:rejected, "over_limit"}, got :accepted
op "o1" finished before reaching a gate; the model keeps it in flight until step 4
op "o2" did not settle within 500ms; in flight: "o1" at gate :after_read (since step 1)
complete of op "o3", which isn't in flight; in flight: "o1", "o2"
op "o1" was started at step 1 and is started again
op "o1" reached gate :after_read; the adapter expected :before_write
the model keeps IncStart in flight (lastResult Pending), but step/2 returned {:ok, …}
the model completes IncDone here, but step/2 returned {:start, "o1", …}
op "o2" raised: ** (RuntimeError) boom
step 4 (Reset) blocked for 2000ms while "o1" was held at gate :after_read
gate :after_read of op "o1" was not released within 5000ms
```

A failure with ops in flight ends with an `in flight:` line, and the
failure map's `in_flight` lists them (`%{op, started_at, at_gate}`).

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
  can't be detected when dropped, so it isn't picked. An op's completion
  is a call: dropped, its op is never released and is cancelled at the
  end. So is an op's start: dropped, the op never runs, and its advances
  and completion are skips. A start counts as changing the state when its
  op's completion does. Advances are never dropped.
- **Serialized op.** For each action that starts ops, the first op that
  overlaps another op (in the first trace where one does) runs through
  every gate to completion at its start; its result is held until its
  completion step. The replay must fail at the start or later. A
  serialization that passes means the replay didn't observe the overlap:
  the gates aren't wired, the race window lies outside them, or the
  projection is blind to it. Some overlaps don't matter, so the next
  overlapping trace is tried until one detects it.

The test fails when a mutant survives, and when something is untested:

```
sensitivity of :counter:
perturbed "counts" at random 0 step 3 was not detected
dropped Reset at random 1 step 6 was not detected
key "plans" never changes in any trace
no step of Refresh changes the state
serializing IncStart is never detected
IncStart never overlaps another op in any trace
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

A start action whose serialization is never detected, or whose ops never
overlap, is allow-listed with `interleavings:`
(`[allow_untested: [interleavings: ["IncStart"]]]`); first check whether a
scenario that overlaps its ops, or a gate in the race window, would test
it.

`sensitivity: true` is `[allow_untested: []]`. An allow-listed key,
action or interleaving that turns out to be tested, or that the check doesn't know, also
fails the test, so the list can't go stale. Actions that only ever return
`{:skip, …}` make no system call and are never checked (the counter's
`Peek`). The `sensitivity:` value must be a literal: the lists can be
written as `~w(plans)`, but not as module attributes or variables.

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

- Concurrent replay controls only what reaches a gate. Gate releases happen
  in the order the trace says, no op passes a gate before the step that
  releases it, and the state is never projected while an op is between
  gates. What happens between two gates (BEAM scheduling, the database's
  locks, `after_action` hooks, jobs sent after a commit) isn't controlled:
  if a race window has no gate, the replay may pass by luck, and a trace is
  deterministic only when its gates cover every racing point.
- Blocked ops are detected by timeout only (`may_block: true`), which is
  timing-based.
- Processes that don't carry `$callers` back to an op task (a GenServer
  the call sends work to, say) aren't gated.
- Op tasks are separate processes: private ETS tables and per-process state
  aren't shared with them. With the Ecto sandbox in shared mode they all
  use the test's connection and its one transaction, so races inside
  transactions (row locks, isolation anomalies) need real connections;
  database support is planned.
- `random:` takes no invariants to check; any non-zero exit of
  `quint run` fails generation.
- Model integers are limited to the signed 64-bit range by Quint.

## License

MIT; see `LICENSE`.
