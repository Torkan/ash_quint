# AshQuint

Test your Ash application against a [Quint](https://quint-lang.org) model
of how it should behave.

You describe a feature as a small state machine in Quint. Quint generates
many executions of it: random runs, the scenarios you name, concurrent
requests that overlap. ash_quint replays each one against your real
resources in ExUnit and checks, after every step, that the system did what
the model said it would.

ash_quint works with any Elixir system, and has helpers for Ash resources
built in.

## What is Quint?

Quint is a specification language for systems whose state changes over
time. It is made by Informal Systems and builds on the logic of TLA+, which
has been used for decades to specify distributed systems. Its syntax reads
like a typed functional language, though, not like mathematics.

A Quint model has three parts:

- **State:** variables, such as the current value of each counter.
- **Actions:** the ways the state can change, such as "increment counter
  `c` by `n`, unless that goes over the limit". An action can pick its
  arguments nondeterministically ("any counter, by 1 or 2"), and the
  model's `step` says which actions may happen next.
- **Properties:** invariants that must hold in every state the system can
  reach, such as "no counter ever goes over the limit".

This is the core of the counter example that ships with ash_quint
(slightly simplified):

```quint
action inc(c: str, by: int): bool = {
  val newCount = valueOf(counts, c) + by
  if (newCount > LIMIT) all {
    counts' = counts,                         // over the limit: nothing changes
    lastAction' = Inc({ ctr: c, by: by }),
    lastResult' = Rejected("over_limit"),
  } else all {
    counts' = counts.put(c, newCount),
    lastAction' = Inc({ ctr: c, by: by }),
    lastResult' = Accepted,
  }
}

val countsWithinLimit = counts.keys().forall(c => counts.get(c) <= LIMIT)
```

Quint's tools then explore the model for you. `quint run` simulates
thousands of random executions and reports any that break an invariant.
`quint test` runs scenarios you write by hand. Any execution can be saved
as a **trace**: the sequence of states the model went through, as JSON (in
the ITF format).

A model has no database, no HTTP and no UI, so Quint can try far more
behaviours than anyone would write tests for. That is how it finds design
mistakes, like a missing guard, a race between two requests or a state you
can't get out of, before any code exists.

## What ash_quint adds

A model on its own only shows that the *design* is right. Nothing checks
that your code matches it, and the two drift apart as the code changes.
ash_quint closes that gap with **model-based testing**:

1. Quint generates traces from your model, and you commit them.
2. Each trace becomes an ExUnit test. ash_quint walks through it step by
   step and makes the real call for each step (an Ash action, usually)
   through a small module you write, the **adapter**.
3. After every step it compares the system with the model. Did the call
   succeed or fail as the model said? Does the state match? Do the
   invariants still hold?

### Why use it

- **Tests you wouldn't think to write.** Random traces combine actions in
  orders nobody writes by hand: a reset after a rejected increment, two
  counters interleaved, the limit hit on the third try. One model gives you
  dozens of tests, and more whenever you ask.
- **Races you can reproduce.** A model can say "these two requests
  overlap": start A, start B, finish B, finish A. ash_quint runs each call
  in its own process and holds it at **gates** you place where the race
  happens, so a lost update or a double spend becomes a step that fails on
  every run, not a flaky test that fails once in a thousand.
- **A spec that can't go stale.** When the model changes, a test fails
  until the traces are regenerated. When the code changes behaviour, a
  replay fails. The model is documentation that every test run checks.
- **Tests that are tested too.** A passing test may be one that checks
  nothing. The sensitivity check breaks replays on purpose (a wrong
  expected value, a call skipped) and fails if your tests don't notice.
- **Bugs become regression tests.** Exploring replays fresh random traces,
  can shrink a failure to a few steps that still fail, and one command
  commits it as a permanent test.
- **No Quint in your test suite.** Traces are generated once, with a pinned
  Quint, and committed. `mix test` needs neither Node nor Quint, and the
  replays run like any other ExUnit test.

ash_quint doesn't replace unit tests: validation messages and
authorization rules are better tested directly. It earns its keep where
behaviour depends on *sequences* of actions: lifecycles and state machines,
balances and limits, multi-step workflows, and anything two users can do
at the same time.

## How it fits together

```text
model.qnt ── mix ash_quint.gen ──▶ traces + manifest.json   (committed)
                                         │
                                  use AshQuint.Case
                                         ▼
                      one ExUnit test per trace ── adapter ──▶ your resources
```

1. You write a Quint model that follows a small convention: it records
   each step's action and result in two variables.
2. `mix ash_quint.gen` runs Quint (random runs, witnesses, scenario tests)
   and writes the traces and a manifest into your repo. You commit them.
3. `use AshQuint.Case` turns every committed trace into an ExUnit test that
   replays it through your adapter. It adds a test that fails when the
   model has changed and the traces are stale, and, if you like, a
   sensitivity test that checks the replays would catch a broken system.

The worked example is the `counter` model: two counters with a limit. The
model and its traces are in
[`priv/examples/counter`](https://github.com/Torkan/ash_quint/tree/main/priv/examples/counter)
(shipped in the package), and its adapter, over an Ash resource, is
[`test/support/counter_adapter.ex`](https://github.com/Torkan/ash_quint/blob/main/test/support/counter_adapter.ex).
The [`race`](https://github.com/Torkan/ash_quint/tree/main/priv/examples/race)
example shows two concurrent increments racing against a limit.

## Using ash_quint in your project

### When building a new feature

Write the model first, then the code.

1. **Sketch the feature as a model.** List its state, the actions that
   change it and what must always be true. Keep it small: two users, two
   records, values from a short set. Most bugs show up in small examples.
2. **Let Quint check the design.** `quint run model.qnt
   --invariant=countsWithinLimit` searches for executions that break an
   invariant. A witness ("a state where the order is refunded") confirms
   that an interesting state can be reached at all. Fixing the design here
   costs nothing: there is no code and no migration yet.
3. **Generate the traces** with `MIX_ENV=test mix ash_quint.gen`, and
   commit them.
4. **Scaffold the adapter and its test** with
   `MIX_ENV=test mix ash_quint.gen.adapter <model>`. It writes one
   `step/2` clause per action, each failing until you fill it in.
5. **Build the resources until the replays pass.** The failing replays are
   your to-do list: each failure names the trace, the step, the action and
   what differed.
6. **Turn on the sensitivity check** to confirm the adapter looks at enough
   of the system, and **explore** for a while to try traces beyond the
   committed ones.

From then on, a change to the feature starts with the model: change it,
regenerate the traces and see which replays fail.

### For existing functionality

Model what the code does now, bugs included, not what it ought to do.

1. **Pick a slice worth modelling.** A resource with a lifecycle
   (subscriptions, orders, approvals), a balance or a quota, an action
   people can trigger twice at once. Not the whole app.
2. **Model the current behaviour** from the actions as they are: their
   validations, their changes, the errors they return. Where you're unsure,
   write down what you believe and let the replays tell you.
3. **Start with a light adapter.** Leave out `project/1` and check what
   each step promises with postconditions, or check only outcomes and
   invariants. Compare more of the state when you need to.
4. **Generate, replay and read the failures.** A failing replay means
   either the model is wrong about the code (fix the model) or the code
   does something nobody intended (you've found a bug). Both are worth
   knowing.
5. **Close the gaps.** Add witnesses for the paths you care about, check
   `mix ash_quint.coverage` for outcomes no trace reaches, and explore to
   find what the committed traces miss. Promote what explore finds to
   regression traces.
6. **For race conditions,** model the overlapping requests as start and
   completion actions and put gates where the race happens (see
   [Concurrency](#concurrency) and [Databases](#databases)).

Once the model matches the code, it is a safety net for refactoring:
rewrite the action, and the replays tell you whether its behaviour changed.

## Installation

ash_quint needs Elixir 1.17 or later. Add it to your dependencies in
`mix.exs`, in every environment:

```elixir
def deps do
  [
    {:ash_quint, "~> 0.1"}
  ]
end
```

Then enable it in the test environment only, in `config/test.exs`:

```elixir
config :ash_quint, enabled: true
```

**Why every environment, and why the switch?** To reproduce a race,
ash_quint needs *gates* in your system's code: in an Ash action, or in code
the action calls (see [Concurrent calls](#concurrent-calls)). That code
runs in dev and prod too, so ash_quint has to be there. Where it isn't
enabled, it is inert: gates compile to no-ops, its application starts
nothing, and replays raise. So you never wrap a gate in
`if Mix.env() == :test`, and dev and prod behave as if ash_quint weren't
installed. Forget the config line, and every replay fails with:

```
ash_quint is disabled in this environment: add `config :ash_quint, enabled: true` to config/test.exs
```

The setting is read at compile time, and Mix recompiles ash_quint when it
changes.

If all your gates live in test-only code (the adapter, telemetry gates, a
test implementation of a behaviour), ash_quint needn't ship in prod:
depend on it with `only: [:dev, :test]` instead, and still enable it in
`config/test.exs`. Not `only: :test`, though: that hides ash_quint's usage
rules for coding agents (`usage-rules.md` and `usage-rules/`, packaged with
the library) from `mix usage_rules.sync`, which runs in dev.

Ash is optional: `AshQuint.Ash` and the Ash-aware default `outcome/1` are
there only when your project depends on `ash`.

Run ash_quint's Mix tasks under `MIX_ENV=test`: explore runs your tests,
and promote reads what explore wrote under `_build/test`. Either prefix
them (`MIX_ENV=test mix ash_quint.gen`) or make `test` their preferred
environment in `mix.exs`:

```elixir
def cli do
  [
    preferred_envs: [
      "ash_quint.gen": :test,
      "ash_quint.coverage": :test,
      "ash_quint.explore": :test,
      "ash_quint.promote": :test,
      "ash_quint.gen.adapter": :test
    ]
  ]
end
```

Generating traces needs Node (for `npx`) or another way to run Quint; see
`quint_cmd` under [Configuration](#configuration). Running the
tests needs neither.

---

The rest of this guide is a reference, in roughly the order you'll need
it:

- [The model convention](#the-model-convention) and
  [Concurrency](#concurrency): what a model must record.
- [Configuration](#configuration),
  [Generating traces](#generating-traces) and
  [Coverage](#coverage): turning a model into
  committed traces.
- [Writing an adapter](#writing-an-adapter),
  [Concurrent calls](#concurrent-calls) and
  [The test case](#the-test-case): connecting the traces to your system.
- [Sensitivity](#sensitivity), [Exploring](#exploring)
  and [Shrinking](#shrinking): checking the tests and finding new bugs.
- [Modelling practices](#modelling-practices), [Databases](#databases),
  [CI](#ci) and [Limitations](#limitations).

## The model convention

A Quint trace records states only, one after another. To replay one,
ash_quint needs to know which action led to each state, with which
arguments, and what that call should have returned. So the model records
both in its own variables (the same convention quint_connect uses):

```quint
type Action = Init | Inc({ ctr: str, by: int }) | Reset(str) | Peek(str)
type Result = Accepted | Rejected(str)

var lastAction: Action   // required; set by every action, init included
var lastResult: Result   // optional; when present, outcomes are asserted
```

- **`lastAction`** is a sum type. The tag is the action's name, and the
  value holds its nondeterministic picks, which become the step's
  `nondet_picks` map:
  - a record value gives its fields (`Inc({ ctr: "c1", by: 2 })` →
    `%{"ctr" => "c1", "by" => 2}`);
  - any other value `v` gives `%{"value" => v}` (`Reset("c1")` →
    `%{"value" => "c1"}`);
  - a unit value (`Init`) gives `%{}`;
  - a Quint `Map` decodes like a record, so `Act(m)` gives the map's
    entries as the picks. Wrap it in a record (`Act({ m: m })`) to keep it
    whole.
- **`lastResult`**, when the model has it, is `Accepted` or
  `Rejected(code)`, and the replay asserts that the system's outcome
  matches. Without it, outcomes aren't asserted. A third variant,
  `Pending`, marks a call still in flight (see
  [Concurrency](#concurrency)).
- **`init`** sets `lastAction` to `Init`. The initial state isn't
  replayed: the adapter's `init/2` sets up the system instead. Then
  `project/1` and `expected/2` are called once on the initial state (step
  0, action `Init`) to record the starting values the sensitivity check
  compares with. Nothing is asserted there, but an exception fails the
  replay at step 0.
- **Every other variable** is model state, which the adapter's projection
  is compared with.
- **Keep model values small and finite** (integers, strings, variants).
  The adapter maps them to real values, for example with `AshQuint.Names`.

The variable names and the initial action's name are configurable
(`action_path`, `result_path`, `init_action`).

**Witnesses and scenarios.** Random runs may rarely reach the states you
care most about. A **witness** is a boolean `val` that becomes true in a
state worth reaching (`val witOverLimit = lastResult ==
Rejected("over_limit")`), and generation looks for a trace that reaches it.
A **scenario** is a `run` you write by hand in a separate tests module,
much like an integration test written in Quint. See
[`model.qnt`](https://github.com/Torkan/ash_quint/blob/main/priv/examples/counter/model.qnt)
and
[`model-tests.qnt`](https://github.com/Torkan/ash_quint/blob/main/priv/examples/counter/model-tests.qnt).

**Things to know about Quint 0.33.1:**

- `set`, `get` and `next` are reserved and can't name a variable or an
  action (QNT101). The counter uses `inc`, `reset` and `peek`.
- Model integers must fit in a signed 64-bit integer. The Rust evaluator,
  Quint 0.33.1's default backend, rejects anything larger (QNT600); the
  TypeScript one doesn't (`backend: "typescript"`, see "Configuration").
  Quint writes integers with |n| ≥ 10^15 as bignumber.js objects rather
  than `#bigint`; ash_quint decodes both to integers.
- `quint run` looks for actions named `init` and `step`. If yours are
  named otherwise, set `init:` and `step:` in the config.
- Variable names are qualified (`tests::model::count`) when a test module
  imports the model as an instance; ash_quint strips the qualifiers.

### Concurrency

Many real bugs are races: two requests read the same row, both pass the
limit check, both write. A model still takes one action per step, but it
can express the overlap by splitting each call into separate **start** and
**completion** actions over an **operation id**:

```quint
type Action = Init | IncStart({ op: str, by: int }) | IncDone({ op: str })
type Result = Accepted | Rejected(str) | Pending
```

A trace can then say "start o1, start o2, finish o2, finish o1", and the
replay makes the real calls overlap in exactly that order.

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
- **In-flight bookkeeping is ordinary model state**
  (`inflight: str -> int`). The adapter doesn't project it, and the
  sensitivity check allow-lists it (`vars:`, see "Sensitivity").
- **Model what the system visibly shows.** The replay compares the state
  at every step, starts included, while calls are in flight, so
  uncommitted writes don't belong in projected variables. For the same
  reason, an invariant that holds only when nothing is in flight is wrong:
  Quint checks it on every state too.
- **You choose the interleaving points.** `IncStart` and `IncDone` give
  "requested" and "returned"; split the action further (`IncRead`) for
  more.

The field and variant names are configurable (`op_field`,
`pending_result`). The manifest marks each trace with a call in flight as
`"concurrent": true`, with the most calls in flight at once as
`"max_in_flight"`. The
[`race`](https://github.com/Torkan/ash_quint/blob/main/priv/examples/race/model.qnt)
example has two `Inc`s against a limit, and a scenario where both start
before either returns.

The replay runs each in-flight call in its own process and holds it at
gates while other steps run; see [Concurrent calls](#concurrent-calls) for
the adapter's side.

## Configuration

`ash_quint.exs`, at the project root, evaluates to a keyword list that
says which Quint to use, where each model lives and which traces to
generate for it. Pinning the Quint version, the
backend and a seed is what makes generation reproducible: the same model
and settings always give the same traces, which is how CI can check them.

Most models need little more than this:

```elixir
[
  quint: "0.33.1",
  backend: "rust",
  models: [
    counter: [
      seed: 20_261_102,
      random: [main: "counter"],
      witnesses: [main: "counter", names: ["witOverLimit"]],
      scenarios: [main: "tests"]
    ]
  ]
]
```

With the defaults, that reads `test/quint/counter/model.qnt` and
`model-tests.qnt` and writes the traces to `test/fixtures/quint/counter`.

Every key, with its default:

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
  # The Quint simulator backend, "rust" or "typescript"; default: unset.
  backend: "rust",
  models: [
    counter: [
      model: "test/quint/counter/model.qnt",        # <model_dir>/<name>/model.qnt
      tests: "test/quint/counter/model-tests.qnt",  # <model_dir>/<name>/model-tests.qnt
      out: "test/fixtures/quint/counter",           # <fixture_dir>/<name>
      on_missing_model: :fail,                      # the top-level setting
      backend: "rust",                              # the top-level setting
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
      ],
      # Shrink explore candidates (see "Shrinking"); default: off.
      shrink: [
        apply: "apply",        # optional: the action that takes an action value
        import: "counter",     # optional: the module or instance to import
        rounds: 20             # optional: the budget of rounds
      ]                        # or shrink: true, every default
    ]
  ]
]
```

- Paths are relative to the project root and must stay inside it,
  including the defaults built from a model's name. They can point
  anywhere in it, even a directory that isn't committed (see
  `on_missing_model`). The manifest records model paths as configured.
- Each model's `out` must be its own directory: not the project root, and
  not another model's `out`.
- `tests` is used only when `scenarios` is set.
- `shrink` is read only by explore (see "Shrinking"), so turning it on
  changes no committed trace, and `mix ash_quint.gen --check` ignores it.
- `backend`, when set, is passed as `--backend=<backend>` to every
  `quint run` and `quint test` that gen and explore run (not to
  `quint compile`), and recorded in the manifest. When it's unset, no flag
  is passed and Quint picks its own default, which can change between
  Quint versions and change the traces with it. So pin it along with the
  Quint version. Quint 0.33.1 defaults to `rust`, whose integers are
  signed 64-bit; a model that needs larger integers pins `typescript`,
  whose integers are unbounded (its traces differ from `rust`'s for the
  same seed).
- Unknown keys, duplicate keys and wrongly typed values are errors that
  name the key, e.g.
  `ash_quint.exs: unknown key models.counter.random.invariants`.

## Generating traces

Running Quint on every test run would be slow, would need Node, and would
make the tests depend on chance. Instead, traces are generated once, on
purpose, and committed like snapshots. You regenerate them when the model
changes, and the diff shows what changed.

```sh
mix ash_quint.gen [model ...] [--check] [--dry-run]
```

Each model can draw traces from three sources, and most use all three:

| Source | Gives you | Good for |
|---|---|---|
| `random:` | random walks through the model | breadth: orders of actions you wouldn't think of |
| `witnesses:` | one trace per named witness that reaches it | the states that matter, guaranteed to be covered |
| `scenarios:` | your hand-written `run` tests | specific stories you want to pin down |

For every configured model (or only those named), from the project root,
the task runs:

- **random:** `quint run <model> --main=<main> --seed=<seed> [--init=…]
  [--step=…] [--max-steps=…] [--max-samples=…] [--n-traces=…]
  --out-itf=…/random_{seq}.itf.json`, named `random 0`, `random 1`, …
  Any non-zero exit is an error.
- **witnesses:** for each name, `quint run … --invariant=not(<name>)
  --out-itf=…/witness_<name>.itf.json`. The witness is reached when Quint
  reports the invariant violated; if it isn't, raise `max_samples` or
  `max_steps`.
- **scenarios:** `quint test <tests> --main=<main> [--match=…]
  --seed=<seed> --out-itf=…/scenario_{test}_{seq}.itf.json`, each renamed
  to `scenario_<test>.itf.json`. Any failing test is an error.

The same seed is passed to `quint test` too, so scenarios that use
`nondet` regenerate byte for byte. Each file is normalized: Quint's
`description` and `timestamp` are removed from `#meta`, and everything
else is kept as written.

**The model interface.** The task also records the model's actions,
results and variables, so that `mix ash_quint.gen.adapter` can scaffold an
adapter and `AshQuint.Case` can warn when the adapter doesn't match the
model. To read them, it runs
`quint compile --target=json --main=<main> <file> --out=…`, with `<main>`
and `<file>` from `random:` (the model file), else `witnesses:` (the model
file), else `scenarios:` (the tests file). A failing compile is an error
with Quint's output. From the compiled model it records:

- **actions:** the variants of the action variable, in declaration order,
  each with its picks: `unit` (no picks), `record` (its fields and their
  types), `value` (one pick, with its type) or `map` (a Quint `Map`).
- **results:** the variant names of the result variable, or `null` without
  one.
- **vars:** every other variable, with its type.

Types are written as Quint text (`str -> int`, `Set[str]`). The JSON IR is
Quint's internal format; if a Quint version changes its shape, the task
fails with `could not read the model interface from Quint <version>'s JSON
IR: …`.

`<out>/manifest.json` (format 3) records the Quint version, the seed, a
hash of each model file, the interface, and each trace's name, source,
step count, actions and, per action, outcomes (see Coverage below). For
the counter example the interface is:

```json
"interface": {
  "actions": [
    {"name": "Init", "picks": "unit"},
    {"fields": [{"name": "ctr", "type": "str"}, {"name": "by", "type": "int"}],
     "name": "Inc", "picks": "record"},
    {"name": "Reset", "picks": "value", "type": "str"},
    {"name": "Peek", "picks": "value", "type": "str"}
  ],
  "results": ["Accepted", "Rejected"],
  "vars": [{"name": "counts", "type": "str -> int"},
           {"name": "writes", "type": "str -> int"}]
}
```

**Flags:**

- Without flags, the task replaces the `*.itf.json` files and
  `manifest.json` in each model's `out` directory and leaves other files
  there alone. Nothing is written unless every model generates. After
  writing a model, it prints the model's coverage table (see below).
- `--dry-run` prints the files that would be added, changed or removed.
- `--check` prints the same and exits with status 1 if anything would
  change; with no changes it prints `ash_quint.gen: traces are current`.

Commit the traces and the manifest.

### Regression traces

When exploring finds a trace that breaks your system, you want that exact
trace to stay in the suite for good, even after the random ones are
regenerated. That's a regression trace:
`<out>/regression_<seed>_<index>.itf.json`, an ordinary trace with its
provenance in one more top-level `#meta` key (the replay ignores the
top-level `#meta`):

```json
"#meta": {
  "format": "ITF", "source": "priv/examples/counter/model.qnt", "status": "ok",
  "ash_quint": {
    "args": ["run", "priv/examples/counter/model.qnt", "--main=counter", "--seed=4031", …],
    "cut_at": 5, "index": 2, "model": "counter", "model_hash": "sha256:…",
    "quint": "0.33.1", "seed": 4031, "steps": 10
  }
}
```

`model_hash` is the model file's hash when the trace was found, `seed` and
`index` are the Quint run and the trace's place in its batch, and `args`
are that run's Quint arguments (without `--out-itf`). The file itself is
the regression: Quint is never rerun for it.

Commit one with `mix ash_quint.promote`:

```sh
MIX_ENV=test mix ash_quint.promote <candidate> ...
```

For each file, it copies it byte for byte to
`<out>/regression_<seed>_<index>.itf.json` and adds its entry (source
`regression`, with its own `seed`) to the model's manifest, without running
Quint:

```
ash_quint.promote: counter: added regression_4031_2.itf.json (5 steps)
```

It checks every file before writing any, and writes nothing if one of
them has a problem:

- the file has no `#meta.ash_quint`;
- the model is unknown, or its manifest is missing or older than format 3
  (run `mix ash_quint.gen` first);
- the `model_hash` differs from the manifest's or the model file's current
  hash (regenerate, and find the trace again);
- the target already exists, or the manifest still lists it after its file
  was deleted (rerun `mix ash_quint.gen` first).

`mix ash_quint.gen` keeps every `regression_*.itf.json` in `out` as it is
and rebuilds its manifest entry, so neither a regeneration nor `--check`
reports it. A regression file without `#meta.ash_quint`, one that isn't
JSON, or one the model's action and result paths no longer read is a gen
error; delete the file if it no longer applies. When the model has changed
since the trace was found, gen keeps it and says so:

```
ash_quint.gen: counter: regression_4031_2.itf.json was found against an earlier model; delete it if it no longer applies
```

Gen can't tell whether the trace is still a behaviour of the new model; a
replay that now fails against a correct system shows that it isn't. To
drop a regression trace, delete its file and rerun `mix ash_quint.gen`: its
manifest entry goes with it.

## Coverage

A green suite doesn't tell you what it covered. If no trace ever has an
increment rejected for going over the limit, the limit isn't tested,
however many traces pass. The coverage table shows, for each action, which
outcomes the committed traces reach:

```sh
mix ash_quint.coverage [model ...]
```

It reads only `ash_quint.exs` and the manifests, so it needs neither Node
nor Quint. For the counter example:

```text
counter: 9 traces, 53 steps
  Inc    23  accepted 20  rejected:over_limit 3
  Peek   20  accepted 20
  Reset  10  accepted 10
```

Each row is one of the model's actions (from the manifest's interface,
leaving out the model's `init_action`), with its step count and then each
result it reaches, with its count. `Accepted` is labelled `accepted`, and
`Rejected(code)` is `rejected:<code>`, so `Rejected("over_limit")` is
`rejected:over_limit`. A step that keeps its call in flight (see
[Concurrency](#concurrency)) is labelled `pending`, and the step that
completes the call counts under its own outcome. For the race example,
where `IncStart` starts a call and `IncDone` completes it:

```text
race: 6 traces, 22 steps
  IncDone   10  accepted 7  rejected:over_limit 3
  IncStart  12  pending 12
```

There are more starts than completions because the `witOverlap` witness
ends with both calls in flight.

**Reading the gaps.** A label missing from a row is an outcome no trace
reaches, such as a rejection the random runs never hit: add a witness or a
scenario for it. An action no trace takes has a row of 0 steps and no
outcomes, as an `Undo` action would if the counter model had one:

```text
counter: 9 traces, 53 steps
  Inc    23  accepted 20  rejected:over_limit 3
  Peek   20  accepted 20
  Reset  10  accepted 10
  Undo    0
```

For a model without `lastResult`, the rows show only the step counts. In a
model with results, steps without one show as `no result <n>`.

`mix ash_quint.gen` prints the same table after writing each model, so a
regeneration shows at once what the new traces reach. `--check` and
`--dry-run` print only the file changes.

**Older manifests.** A manifest written by ash_quint 0.1.0 (format 1) has
no outcomes: replays still work with it, but `mix ash_quint.coverage` asks
you to regenerate it with `MIX_ENV=test mix ash_quint.gen <model>`. A
format 2 manifest has no interface: its table lists only the actions the
traces take and ends with `(actions no trace takes aren't listed:
regenerate with mix ash_quint.gen <model> to record the model's actions)`.

## Writing an adapter

The model talks about counter `"c1"` and "Inc by 2". Your system has
UUIDs, Ash actions and database rows. The adapter translates between the
two: for each model step it makes the real call, and it reports the
system's state in the model's terms so the two can be compared.

Start from the scaffold that `mix ash_quint.gen.adapter` writes from the
model interface in the manifest (it doesn't run Quint):

```sh
MIX_ENV=test mix ash_quint.gen.adapter counter [--adapter MyApp.CounterTrace] [--force]
```

It writes two files, asking before it overwrites either unless given
`--force`:

- `test/support/counter_trace.ex`, the adapter (module `<App>.CounterTrace`,
  or `--adapter`). It has a `step/2` clause per action (except
  `init_action`) that binds the action's picks, and a `project/1` with
  every model variable, its type as a comment.
- `test/counter_trace_test.exs`, its test module (`<adapter>Test`, with
  `use AshQuint.Case, model: :counter, adapter: …, sensitivity: true`, and
  comments on `traces:` and `explore:`).

Each body is a `todo!/1` that raises
`<adapter>: <what> is not implemented yet`, so the files compile without
warnings and every replay fails at its first step until you fill them in:

```elixir
# Inc({ ctr: str, by: int })
@impl true
def step(ctx, %Step{action_taken: "Inc", nondet_picks: %{"ctr" => ctr, "by" => by}}) do
  {:ok, todo!("Inc(ctr: #{inspect(ctr)}, by: #{inspect(by)})"), ctx}
end
```

`test/support` must be compiled in the test environment. Phoenix projects
already have this in `mix.exs`; otherwise add it:

```elixir
defp elixirc_paths(:test), do: ["lib", "test/support"]
defp elixirc_paths(_env), do: ["lib"]
# in project/0: elixirc_paths: elixirc_paths(Mix.env())
```

For a concurrent model, the manifest's outcomes pick the form: an action
whose steps are all `Pending` gets `{:start, op, fn -> … end, ctx}`, and
one with other outcomes gets `{:complete, op, ctx}`. Drop the model's
bookkeeping variables from `project/1` and allow-list them with
`sensitivity: [allow_untested: [vars: […]]]`. A manifest older than
format 3 has no interface: regenerate it with `mix ash_quint.gen` first.

The counter's adapter, filled in:

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

### The callbacks

Only `init/2` and `step/2` are required; the rest let you check more.

- **`init(trace, opts)`** builds a fresh `ctx` for one trace; `opts` is the
  case's `adapter_opts`. Use a map if you use `AshQuint.Names`.
- **`step(ctx, step)`** performs one step, matching on
  `step.action_taken` and `step.nondet_picks`. It returns one of:
  - `{:ok, result, ctx}` after a system call. `outcome(result)` must match
    the model's `lastResult`.
  - `{:pending, ctx}` when the action only starts a call that a later step
    completes (a create that a later commit finishes). Nothing is compared
    until that step returns `{:ok, …}`. This is the sequential form: a
    trace with two pending steps open, a skip while one is pending, or a
    pending step at the end fails.
  - `{:skip, ctx}` for a model-only step: the state is compared, but no
    outcome is asserted.
  - `{:start, op, call, ctx}`, `{:advance, op, ctx}` and
    `{:complete, op, ctx}` for calls that stay in flight while other steps
    run: see [Concurrent calls](#concurrent-calls).
- **`project(ctx)`** (optional) returns the system's state, keyed by the
  model variables it covers, in the model's terms. Only those keys are
  compared; without `project/1`, none is.
- **`expected(ctx, step)`** (optional) returns the model's value for each
  projected key. The default takes them from `step.state` as they are;
  define it when the model's values need translating.
- **`outcome(result)`** (optional) classifies a call's result as
  `:accepted`, `{:rejected, code}` or `{:failed, message}`. The default is
  `AshQuint.Ash.outcome/1` when Ash is available where the adapter is
  compiled, and otherwise `AshQuint.Adapter.default_outcome/1` (`:ok` and
  `{:ok, _}` are accepted). An adapter that implements the behaviour
  without `use AshQuint.Adapter` gets the same default at run time. Pass
  `codes:` to `AshQuint.Ash.outcome/2` to map your error modules to the
  model's rejection codes.
- **`invariants()`** (optional) lists `{name, fun}` checks run after every
  synced step: `fun.(projected, ctx)` returns `:ok` or `{:error, message}`.
- **`postconditions()`** (optional) lists `{name, fun}` checks of what each
  step promises. They run after the state comparison and the invariants on
  every synced step (not after `{:pending, …}`, and not on the initial
  state). `fun.(ctx, step)` gets the step's `ctx` and the model step (its
  picks, model state and result) and returns `:ok` or `{:error, message}`.
  It reads the system itself, or what `step/2` kept in `ctx`. A failure
  reads `postcondition <name>: <message>`; an exception,
  `postcondition <name> raised: <message>`.
- **`finish(ctx, result)`** (optional) runs exactly once when a replay
  ends, with the latest `ctx`: with `:ok` after the last step's checks,
  with `{:error, failure}` at the first failing step, and, when an adapter
  callback raises, with the `ctx` that callback was given, before the
  exception propagates. Release what `ctx` holds there. Return `:ok`, or
  `{:error, message}` to fail a passing replay at its last step (an
  end-of-trace check, such as a witness reached on the real system); on a
  failing replay the original failure is kept.

### Light adapters

Projecting the whole state can be a lot of work for an existing feature.
A light adapter leaves out `project/1` and instead checks what each step
promises with postconditions. The counter's, with the same `step/2`:

```elixir
@impl true
def postconditions, do: [count_matches: &count_matches/2]

# After a step on counter `ctr`, its row holds the model's count.
defp count_matches(ctx, %Step{nondet_picks: picks, state: state}) do
  case picks["ctr"] || picks["value"] do
    nil ->
      :ok

    ctr ->
      # read_count/2 reads the count of the row named ctr.
      {actual, expected} = {read_count(ctx, ctr), state["counts"][ctr]}
      if actual == expected, do: :ok, else: {:error, "#{ctr}: count #{actual}, model #{expected}"}
  end
end
```

Outcomes, invariants and postconditions are checked as usual; no key is
compared. An adapter with neither `project/1` nor postconditions checks
outcomes and invariants only. See [Sensitivity](#sensitivity) for what the
check tries on such an adapter.

### Two rules that matter in practice

- **Scope `project/1` to the trace.** The sensitivity check replays every
  trace and mutant one after another in one test, so the database holds
  the rows of earlier replays. Read only what this trace created: a tenant
  made in `init/2`, or the ids it named (the counter keeps them in
  `ctx.ids`). For the same reason, release in `finish/2` whatever a replay
  holds open (processes, transactions, checked-out connections, locks):
  mutants fail partway through, and without `finish/2` what they opened
  stays alive until the test process exits.
- **Transition invariants go through `ctx`.** An invariant sees only the
  projection and `ctx`. One that compares a step with the one before keeps
  what it needs (the rows before the call, say) in `ctx`, from `step/2`.

### Helpers

- `AshQuint.Names` maps the model's small values (`"c1"`, `1`) to real ones
  (UUIDs by default), fresh per trace, and back again for projections.
- `AshQuint.Ash.read_map/2` snapshots a resource as a map keyed by one
  field; `AshQuint.Ash.sql_rows/3` snapshots raw SQL rows, for state Ash
  doesn't read one row per record.
- `AshQuint.Ash.Gate` gates an Ash action; `AshQuint.Gate.Telemetry` gates
  at telemetry events; `AshQuint.Ash.pg_backend_pid/1` and
  `AshQuint.Ash.pg_blocked?/2` report ops blocked on Postgres locks (see
  [Databases](#databases)).

### Concurrent calls

To reproduce a race, the overlapping calls have to really overlap:
running one after the other would hide the bug. So for a model that lets
calls overlap (see [Concurrency](#concurrency)), the adapter starts the
real call at the start step, and the replay runs it in an **op task**, a
process of its own, while the trace goes on:

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
  `step.op`, and it must not already be in flight. The step must be
  `Pending` in the trace.
- **`{:advance, op, ctx}`** releases `op` from its gate and waits until it
  stops at the next one. It is for models that split one call into more
  than two steps (`IncStart`, `IncRead`, `IncDone`). The step must be
  `Pending`.
- **`{:complete, op, ctx}`** releases `op` through every remaining gate,
  waits for its result and checks `outcome(result)` against the step's
  `lastResult`, as for `{:ok, …}`. The step must not be `Pending`.
- `{:ok, …}`, `{:skip, …}` and `{:pending, …}` still run in the test
  process while ops are in flight.

**Gates** are where an op task stops and waits for the replay. Put
`AshQuint.Gate.checkpoint/1` in the system's code path, where the race can
happen:

```elixir
change fn changeset, _context ->
  count = Ash.Changeset.get_data(changeset, :count)
  AshQuint.Gate.checkpoint(:after_read)
  # …
end
```

Outside an op task it returns `:ok` at once, and where ash_quint isn't
enabled (see [Installation](#installation)) it compiles to a plain `:ok`,
so the gate can stay in the code in every environment. Inside an op task,
it waits for the replay. Processes the call starts with `Task` gate
their op too, since the gate looks up `$callers`. Gate names are your own
atoms (or tuples). The Ash change `AshQuint.Ash.Gate` and telemetry gates
(`AshQuint.Gate.Telemetry`) place gates without editing the action's code;
see [Databases](#databases).

**Settling.** After every step, the replay waits until each op in flight
is at a gate or has finished, then compares the state and runs the
invariants, on every step, starts included. An op that does neither within
`settle_timeout` fails the step, unless it was started with
`may_block: true`: then it counts as blocked (on a lock another op holds,
say), and the replay waits for it again after the next release. An adapter
that can tell when an op is blocked defines the optional
`blocked?(ctx, op_info)`: the replay asks it every 10 ms about the ops
still running, and an op it says is blocked settles at once, without
waiting out the timeout. The call records what it may wait on with
`AshQuint.Gate.put_info/2`; for Postgres, see [Databases](#databases).

**Options**, as a fifth element (`{:start, op, call, ctx, opts}`) or a
fourth (`{:advance, op, ctx, opts}`):

- `early: :ok` (start only): the call may finish before it reaches a gate.
  Without it, that fails: an op that returns at its start step overlapped
  nothing. Its result is held until its completion step either way.
- `may_block: true`: see Settling.
- `at: name`: the gate the op must reach (the first one for a start, the
  next one for an advance); another gate fails the step, naming both.

**Nothing hangs.** A synchronous step (`{:ok, …}`) that blocks on
something a gated op holds is released by a watchdog after
`step_timeout`: it frees every gated op and fails the step. A gate that
the replay doesn't release within `gate_timeout` returns anyway and fails
the step the replay is on, so a wrong release order can't hang the test.
A trace that ends with ops in flight passes: they are cancelled unchecked
(random traces stop at `max_steps`, often mid-call). Every op task is
stopped before `finish/2` runs, on every path, so `finish/2` can release
what the ops used.

The timeouts are `AshQuint.Replay.run/3` options in milliseconds:
`settle_timeout` (default 500), `step_timeout` (2000), `complete_timeout`
(5000, for a completed op's result) and `gate_timeout` (5000).
`AshQuint.Case` uses the defaults unless you pass `replay:`.

The race example's adapter,
[`test/support/race_adapter.ex`](https://github.com/Torkan/ash_quint/blob/main/test/support/race_adapter.ex),
replays every race trace against an ETS resource with an atomic
increment; with its read-modify-write `:inc` action instead, `raceTest`
fails at step 4 on the lost update. It shows two things:

- **Make the call do the read.** Fetch the record inside `call`, not in
  `step/2`, so the read happens in the op task, between the gates.
- **Op tasks are other processes.** A `private? true` ETS table is visible
  only to its owner, so concurrent replays need a table that isn't
  private, scoped by the ids the trace names. Database sandboxes allow op
  tasks through `$callers`, but all of them share the test's connection
  (see [Databases](#databases)).

An op task gets the test process's Ash tracer span context (the tracers
configured for `:ash`), so its spans nest under the test's. Actor and
tenant aren't process state: pass them in the call's options, which `call`
closes over.

## The test case

This is where the committed traces become ExUnit tests:

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

- **one test per trace**, named `"random 0"`, `"witness witOverLimit"`,
  `"scenario incTest"` or `"regression 4031_2"`, tagged `quint: <source>`
  and `quint_model: <model>`, and `quint_concurrent: true` when the
  manifest marks the trace concurrent. A regression trace (see "Regression
  traces") is replayed with the seed it was found with, the others with
  the manifest's;
- **a staleness test**, `"traces for counter are current"`, which fails
  when a model file's hash no longer matches the manifest: run
  `mix ash_quint.gen counter`;
- with `sensitivity:`, **`"sensitivity of counter"`**, tagged
  `quint_model: <model>` and `quint_sensitivity: <model>` (see
  [Sensitivity](#sensitivity));
- with `explore: true` (or `explore: [max_steps: 20, batch: 25]`),
  **`"explore counter"`**, which replays fresh traces and is excluded from
  the suite (see "Exploring").

The config, manifest, traces and model files are external resources, so
the module recompiles when they change. An unknown model, a missing
manifest or one without traces is a compile error.

**Running a subset.** Select the tests by tag:
`mix test --only quint_model:counter`, `mix test --only quint:witness`,
`mix test --only quint:regression`. The sensitivity test replays every
trace again; a quick alias can skip it for every model with
`mix test --exclude quint_sensitivity`.

### The adapter check

Mistakes in the adapter, such as a misspelled action name, a pick the
action doesn't have or a forgotten action, would otherwise only show up as
failing replays. With a format 3 manifest, `AshQuint.Case` checks the
adapter's `step/2` clauses against the model interface at compile time,
reading them from the compiled adapter's debug info, and warns at the
`use` line:

```
warning: MyApp.CounterTrace has a step/2 clause for "Incr", which isn't an action of :counter (actions: Inc, Reset, Peek)
warning: MyApp.CounterTrace step/2 clause for "Inc" matches pick "amount", which Inc doesn't have (picks: ctr, by)
warning: MyApp.CounterTrace has no step/2 clause for "Reset" of :counter
```

The last warning is never given for `init_action`, nor when a clause
matches any action, as a delegating adapter's `def step(ctx, step)` does.
A clause counts when its second argument is a `%AshQuint.Step{}` or plain
map pattern with a literal `action_taken` and, for the picks, a literal
`nondet_picks` map. Map picks aren't checked. An adapter without debug
info (one defined in the test file itself, say) isn't checked.
`mix test --warnings-as-errors` turns the warnings into failures.

### Splitting sequential and concurrent traces

Concurrent traces run their calls in op tasks, other processes than the
test's. A private ETS table, per-process state or a database sandbox in
manual mode doesn't reach them. `traces: :sequential` or
`traces: :concurrent` splits one model's traces between two modules, so
the sequential ones stay in the async module and the concurrent ones run
where op tasks can see the data:

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
    sensitivity: [allow_untested: [vars: ~w(inflight finished)]],
    replay: [settle_timeout: 1_000]
end
```

`traces:` is `:all` (the default), `:sequential` or `:concurrent`; a
selection with no trace is a compile error. Each module has its own
staleness test, and the sensitivity check runs over its traces only. The
`quint_concurrent` tag selects the concurrent replays across modules:
`mix test --only quint_concurrent`.

### Other options

- `replay:` passes the replay's timeouts (`settle_timeout`,
  `step_timeout`, `complete_timeout` and `gate_timeout`, in ms; see
  "Concurrent calls"); any other key is a compile error.
- `sandbox: MyApp.Repo` gives each replay of the explore and sensitivity
  tests a sandbox transaction of its own (see
  [One transaction per trace](#one-transaction-per-trace-sandbox)); the
  trace tests replay in the template's sandbox as before. It must be a
  module name.
- If your model files aren't committed (they live in an ignored planning
  directory, say), set `on_missing_model: :skip` in `ash_quint.exs`. The
  staleness test is then skipped when the model file is missing; the
  replays still run, since they need only the committed traces. With the
  default `:fail`, a missing model file fails it.

### Failures

When a replay fails, you want to know exactly where the model and the
system disagree, and how to get the same trace again. Every replay failure
names the trace, step, action and seed, lists all of that step's problems,
and ends with the model's step (its picks and result, as the trace has
them) and, in `AshQuint.Case`'s tests, the trace file:

```
counter random 3, step 4 (Inc), seed 20261102: outcome: expected :accepted, got {:rejected, "over_limit"}
model step: Inc %{"by" => 2, "ctr" => "c1"}, result :accepted
trace: priv/examples/counter/traces/random_3.itf.json
```

The prefix up to the first problem keeps this shape:
`<model> <source> <name>, step <i> (<action>), seed <seed>: `. The
`model step:` line leaves out empty picks and a missing result, and a
failure at step 0 has none.

A regression trace with provenance (see "Regression traces") adds the
command that regenerates it, after its `trace:` line:

```
quint: npx --yes @informalsystems/quint@0.33.1 run priv/examples/counter/model.qnt --main=counter --seed=4031 --max-steps=10 --max-samples=20 --n-traces=20 --backend=rust --witnesses witOverLimit witResetAfterInc '--out-itf=explore_{seq}.itf.json' (trace 2)
```

`(trace 2)` is the trace's place among the run's outputs
(`explore_2.itf.json`). The Quint version is the one the trace was explored
with. Words with characters outside `[A-Za-z0-9_./=:@+-]` are
single-quoted (braces and commas included, against brace expansion). A
shrunk regression trace (see "Shrinking") then adds its steps as a Quint
run:

```
run:   init.then(inc("c1", 1))
```

The `quint:` line still regenerates the batch's original trace, as explore
found it (before the cut and the shrinking); the `run:` line is the shrunk
trace's steps. Callers of `AshQuint.Replay.run/3` append their own lines
with the `:context` option.

**What counts as a problem:**

- an outcome mismatch, or a failed system call (`{:failed, message}`);
- a missing `step/2` clause, or a bad return value;
- a projected key that differs from the model, or has no expected value;
- a failing invariant, or a failing (or raising) postcondition;
- an interleaved trace (overlapping `{:pending, …}` steps), or a model and
  adapter that disagree on which steps keep a call in flight;
- an op's problems (below);
- an exception from `project/1` or `expected/2` on the initial state (at
  step 0), and an `{:error, message}` from `finish/2` (at the last step).

Other exceptions from the adapter propagate as they are, without the
prefix. That includes a missing clause in a helper that `step/2` delegates
to: only a `FunctionClauseError` from the adapter's own `step/2` is
reported as a missing clause.

A projected key that differs shows both values:

```
key "count":
  expected: 1
  actual:   0
```

When either value is long (over 60 characters or several lines) and both
are maps or both are `MapSet`s, only the differences are listed, depth
first, keys sorted, with the path of keys (at most 20 lines, then
`… and 7 more differences`):

```
key "counts":
  "c1": expected 3, actual 4
  "c2": missing (expected 0)
  "c3": unexpected (actual 1)
  "c4" > "limit": expected 3, actual 5
  "done": missing ["o1"], unexpected ["o3"]
```

Any other long pair is shown whole.

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

A failure with ops in flight ends its problems with an `in flight:` line
(before the `model step:` line), and the failure map's `in_flight` lists
them (`%{op, started_at, at_gate}`).

## Sensitivity

A replay that passes may not prove much. If `project/1` forgets the
column that matters, or the adapter's call doesn't really reach the
database, every trace still passes. `sensitivity: true` adds a test that
checks the replays themselves: it replays **mutants**, deliberately broken
versions of the traces that a meaningful replay must fail.

- **Perturbed expectation.** For each projected key, the first step where
  the model's value changes gets a wrong expected value. The replay must
  fail there, on that key.
- **Dropped call.** For each action that makes system calls, the first
  call that changes the model's state is skipped instead of made. The
  replay must fail at that step or later. A rejected call, or one that
  changes nothing, can't be detected when dropped, so it isn't picked. An
  op's completion is a call: dropped, its op is never released and is
  cancelled at the end. So is an op's start: dropped, the op never runs,
  and its advances and completion are skips. A start counts as changing
  the state when its op's completion does. Advances are never dropped.
- **Serialized op.** For each action that starts ops, the first op that
  overlaps another op (in the first trace where one does) runs through
  every gate to completion at its start; its result is held until its
  completion step. The replay must fail at the start or later. A
  serialization that passes means the replay didn't observe the overlap:
  the gates aren't wired, the race window lies outside them, or the
  projection is blind to it. Some overlaps don't matter, so the next
  overlapping trace is tried until one detects it.

**Unprojected variables.** A model variable that no projection covers is
untested too. The check compares the traces' variables (all but
`lastAction` and `lastResult`, or the roots of `action_path` and
`result_path`) with the keys the replay compared, so a variable the
adapter forgot to project shows up. Keys the adapter projects under names
that aren't model variables aren't checked.

**Adapters without `project/1`** project nothing on purpose: they get no
perturbed expectations and no variable check. With `postconditions/0`,
each action none of whose calls changes the expected state (with no
projection, every action) gets one more dropped call, at its first call
whose model result is `Accepted`. The postconditions run on the skipped
step, so one that notices the missing effect fails the replay, and the
action counts as tested. If none notices, the mutant isn't reported as a
survivor: the action stays untested (and can be allow-listed like any
other). Adapters without postconditions get exactly the mutants above.

The test fails when a mutant survives, and when something is untested:

```
sensitivity of :counter:
perturbed "counts" at random 0 step 3 was not detected
dropped Reset at random 1 step 6 was not detected
key "plans" never changes in any trace
no step of Refresh changes the state
serializing IncStart is never detected
IncStart never overlaps another op in any trace
variable "plans_seen" is never projected
```

**Fixing what it reports.** An untested key or action usually means a
coverage gap: a path no random run, witness or scenario reaches. Add a
witness or scenario for it. For deliberate constants (setup picked with
`nondet` in `init` and never changed), allow-list them:

```elixir
use AshQuint.Case,
  model: :billing,
  adapter: MyApp.BillingTrace,
  sensitivity: [allow_untested: [keys: ["plans"], actions: ["Refresh"]]]
```

A start action whose serialization is never detected, or whose ops never
overlap, is allow-listed with `interleavings:`
(`[allow_untested: [interleavings: ["IncStart"]]]`). First check whether a
scenario that overlaps its ops, or a gate in the race window, would test
it.

A model variable the adapter deliberately doesn't project, such as
in-flight bookkeeping or model-only state, is allow-listed with `vars:`.
The race example's `inflight` and `finished` say which ops are in flight
and which have completed; the system has no such state:

```elixir
sensitivity: [allow_untested: [vars: ~w(inflight finished)]]
```

`sensitivity: true` is `[allow_untested: []]`. An allow-listed key,
action, interleaving or variable that turns out to be tested (for a
variable: projected), or that the check doesn't know, also fails the test,
so the list can't go stale. Actions that only ever return `{:skip, …}`
make no system call and are never checked (the counter's `Peek`). The
`sensitivity:` value must be a literal: the lists can be written as
`~w(plans)`, but not as module attributes or variables.

## Modelling practices

A model is only as useful as what it says. These practices are borrowed
from Quint's own write-ups on model-based testing and specification, and
mapped to ash_quint. None of them is enforced; the library's checks (the
replays, sensitivity, the adapter check, explore) are what make them pay
off.

**Model what the code does, bugs included.** "The model's job is to
faithfully represent what the code does, including its rounding choices
and its mistakes" ([Balancer](https://quint.sh/posts/balancerbug)). A
replay checks that the system does what the model says. A model of the
intended behaviour fails on the bug at a replay step, while a model of the
actual behaviour lets Quint name the bug as a violated invariant. Change
the model along with the code, and regenerate: the staleness test fails
until you do, and explore and promoted regression traces keep the two in
step.

**One invariant per property.** Give each property its own named
invariant, in the model and in the adapter's `invariants/0` (the counter's
`countsWithinLimit` and `counts_within_limit`). A tighter invariant gives a
shorter violating trace, and the failure says which property broke
([MonadBFT](https://quint.sh/posts/monadbft) checks each supporting lemma
as a separate invariant).

**Storage consistency.** A cached or stored value must stay faithful to
what it represents; Balancer's invariant compares a stored value with one
recomputed from its sources. In Ash, that is a stored attribute against an
aggregate or calculation over its source, checked by an adapter invariant
that loads both:

```elixir
# In the resource: aggregates do sum :entries_total, :entries, :amount, default: 0 end
require Ash.Query

@impl true
def invariants, do: [balance_matches_entries: &balance_matches_entries/2]

defp balance_matches_entries(_projected, ctx) do
  MyApp.Account
  |> Ash.Query.filter(id in ^ctx.ids)
  |> Ash.Query.load(:entries_total)
  |> Ash.read!()
  |> Enum.find_value(:ok, fn account ->
    if account.balance != account.entries_total,
      do: {:error, "#{account.id}: balance #{account.balance}, entries #{account.entries_total}"}
  end)
end
```

The invariant reads the system, not the projection, so it holds the
system to a property the model needn't spell out.

**Check that an invariant is specific.** Balancer confirms its invariant
catches the bug, not "any exit", by running a step without the buggy path
and expecting no violation (`--step=stepWethOnly` in the post; for your
model, say, `quint run model.qnt --invariant=inv --step=stepClean`). The
converse validates the model: [Reliable Software in the LLM
Era](https://quint.sh/posts/llm_era) specifies a version with too many
faulty nodes and expects the property to break. ash_quint's `random:`
takes no invariant (see [Limitations](#limitations)), so run these
yourself.

**Honest and malicious actions side by side.**
[Zerocash](https://quint.sh/posts/zerocash) puts a malicious action next
to its honest version, through the same validation, and picks the mix with
`--step` (`--step=faerie_gold_step`). In ash_quint, `random: [step: …]` and
`witnesses: [step: …]` choose the step the traces come from, and explore
uses `random:`'s.

**Failures as actions.**
[Emerald](https://quint.sh/posts/quint_connect_emerald) models process
restarts and data corruption as spec actions, replayed as adversarial
scenarios; in MonadBFT, Byzantine validators take adversarial actions like
any other. Add them to the model's `Action` type (`Restart`, `LoseWrite`),
and have `step/2` make them happen: kill a process, roll back a
transaction, delete a row behind the system's back.

**Witnesses for reachability.** The post writes witnesses as negated
invariants, so a violation proves a state reachable
([cognitive debt](https://quint.sh/posts/cognitive_debt)). In ash_quint you
write the reached-state predicate itself, and gen negates it
(`--invariant=not(<name>)`). One per key scenario in
`witnesses: [names: …]` gives a committed trace that reaches it. Explore
reports how often fresh traces reach each witness
(`quint run --witnesses`, which counts the traces where the predicate
holds); one that reads `never` is a scenario the random traces don't test,
and the coverage table shows the outcomes no trace reaches.

**Runs as scenarios.** A `run` is a sequence of concrete steps, "like a
high-level integration test" (cognitive debt). Put them in
`model-tests.qnt` and list them under `scenarios:`; Emerald keeps its most
interesting scenarios in the codebase as Quint runs. A failure explore
finds is kept the same way, as a promoted regression trace (see
"Regression traces"). With `shrink:`, explore also prints the shrunk trace
as a run, `run:       init.then(inc("c1", 1))`, and the promoted test
prints it as `run:   …`: paste it into `model-tests.qnt` as
`run regression4031Test = …` to keep it as a scenario too.

**Postconditions for light models.** Neutron's model was "lightweight and
nimble": correctness was checked by postconditions on the executed actions
([Neutron](https://quint.sh/posts/neutron-mbt)). An adapter can do the same
with `postconditions/0` and no `project/1` (see
[Light adapters](#light-adapters)); sensitivity then drops one accepted
call per action to check that a postcondition notices.

**Model-based testing complements other tests.** From Interchain
Security's MBT setup: "MBT cannot replace diligent unit and end-to-end
testing, but it can add value to them"
([tests/mbt](https://github.com/cosmos/interchain-security/blob/main/tests/mbt/README.md)).
Keep the unit tests for validation, authorization and error messages,
which a model abstracts away.

**Let an agent draft, let the tools decide.** "LLMs don't think, they
translate. Quint's deterministic tools do the reasoning" (LLM era), and
the spec is validated (reachability, the over-faulty variant) before the
code is generated from it. Quint Connect's driver library was designed to
work with LLMs: "The Quint Connect library will tell you what's missing"
([Quint Connect](https://quint.sh/posts/quint_connect)). In ash_quint,
`mix ash_quint.gen.adapter` writes the skeleton, the adapter check warns
about actions and picks the adapter gets wrong, and a failure names the
model step and, for a trace explore found, the command that regenerates
it. Trust what an agent drafts only once `quint typecheck`, `quint test`
and `quint run` pass on the model and the replays and sensitivity pass on
the adapter. In the [OpenHands race](https://quint.sh/posts/racecondition),
an agent drafted the fix, and checking it against the Quint model showed
it was incomplete.

**Pin the backend and the Quint version.** `quint:` and `backend:` in
`ash_quint.exs` (see "Configuration") keep the traces reproducible, and
`mix ash_quint.gen --check` in CI shows when they no longer are.

## Exploring

The committed traces are a fixed sample. They pass today, but a bug can
hide in an order of actions none of them happens to take. Exploring
replays fresh ones: each run asks Quint for new random traces of the
model, replays them against the system like the committed ones, and
reports every failure as a candidate regression trace you can commit.

Add `explore:` to the model's test module:

```elixir
use AshQuint.Case,
  model: :counter,
  adapter: MyApp.CounterTrace,
  explore: true            # or [max_steps: 20, batch: 25]
```

It defines `"explore counter"`, tagged `quint_explore: :counter` and
`timeout: :infinity`, but not `quint_model:`, so
`mix test --only quint_model:counter` leaves it out. `max_steps` is the
length of the fresh traces (default: the model's `random:` `max_steps`,
else Quint's), and `batch` the traces per `quint run` (default 20; each
run costs about a second, mostly Node start-up). The model needs
`random:`: its `main`, `init` and `step` are used. Any other key is a
compile error.

The test runs Quint, so keep it out of the suite in
`test/test_helper.exs`:

```elixir
ExUnit.start(exclude: [:quint_explore])
```

Run any other way than below, it fails at once:
`explore test for :counter ran without mix ash_quint.explore; add :quint_explore to ExUnit.start(exclude: …) in test/test_helper.exs`.

Run it with:

```sh
MIX_ENV=test mix ash_quint.explore [model ...] [--runs N] [--seed S] [--budget SECONDS] [--failures N]
```

The task checks the models against `ash_quint.exs` and runs
`mix test --only quint_explore:<model>` (every explore test, when no model
is named) with the settings in environment variables:

| Flag | Variable | Default | Meaning |
|---|---|---|---|
| | `ASH_QUINT_EXPLORE` | — | must be `1`; the task sets it |
| `--runs` | `ASH_QUINT_EXPLORE_RUNS` | 100 | fresh traces to generate |
| `--seed` | `ASH_QUINT_EXPLORE_SEED` | random | base seed |
| `--budget` | `ASH_QUINT_EXPLORE_BUDGET` | none | wall-clock seconds; no new batch starts after it |
| `--failures` | `ASH_QUINT_EXPLORE_FAILURES` | 1 | stop after this many failures |

`ASH_QUINT_EXPLORE=1 mix test --only quint_explore` is the same run
without the task. A malformed value fails the test naming the variable;
when no explore test runs, the task fails asking for `explore: true`.

**How a session runs.** Each batch k is one `quint run` with seed
`base + k`, the model's `random:` options and `--n-traces` equal to
`--max-samples`. Each trace is replayed in the test process, with the
module's adapter, `adapter_opts`, `replay:` and `traces:` selection; a
fresh trace the selection leaves out (by the same rule as the manifest's
`concurrent`) is counted as skipped. All replays share the test's sandbox,
as the sensitivity check's do, unless the module sets `sandbox:` (see
[One transaction per trace](#one-transaction-per-trace-sandbox)), which a
long session on Postgres needs.

A passing session prints one line, and a second when the model's
`witnesses:` have the same `main` as `random:`:

```
explore counter: 100 traces (seeds 4031..4035), 0 failures, 0 skipped
witnesses: witOverLimit 35/100 (35.0%), witResetAfterInc 100/100 (100.0%)
```

**Witness rates** tell you how well the fresh traces cover the states you
named. Each batch then ends with `--witnesses <names…>`, and Quint counts,
per witness, the fresh traces in which it holds in some state; the line
sums them over the batches. A witness with 0 hits reads `0/100 (never)`:
the fresh traces never reach that scenario, so they never test it (raise
`max_steps`, or make a step favour it). When a batch's output lacks a
witness's count, the line reads
`witnesses: counts not found in Quint's output`. Witnesses of another
module get no rates. The summary line is printed even when the session
fails.

**When a trace fails.** A trace is named `"<seed>_<index>"`, so its
failure message is the start of the one its regression test will print
(which adds the `trace:` and `quint:` lines, and `run:` for a shrunk one).
A replay failing at step N is cut to its states 0..N and replayed once
more: when it fails at N again, the cut trace is the candidate; otherwise
(a race window without a gate, say) the full trace is. An exception from
the adapter is a failure too, with the full trace. The candidate gets its
provenance in `#meta.ash_quint` and is written to
`_build/<env>/ash_quint/explore/<model>/`, and the test fails listing each
one with the command that regenerates its trace and the one that commits
it:

```text
explore counter: 1 failure in 100 traces (seeds 4031..4035)

counter regression 4031_2, step 5 (Inc), seed 4031: key "counts":
  expected: %{"c1" => 3}
  actual:   %{"c1" => 4}
model step: Inc %{"by" => 1, "ctr" => "c1"}, result :accepted
candidate: _build/test/ash_quint/explore/counter/regression_4031_2.itf.json (cut to 5 steps)
quint:     npx --yes @informalsystems/quint@0.33.1 run priv/examples/counter/model.qnt --main=counter --seed=4031 --max-steps=10 --max-samples=20 --n-traces=20 --backend=rust --witnesses witOverLimit witResetAfterInc '--out-itf=explore_{seq}.itf.json' (trace 2)
promote:   MIX_ENV=test mix ash_quint.promote _build/test/ash_quint/explore/counter/regression_4031_2.itf.json
```

The note after the path is `cut to N steps`, `not cut` (the failure was at
the last step), `did not reproduce on a second replay; full trace` or
`adapter raised; full trace`. Fix the bug, promote the candidate (see
"Regression traces"), and the committed suite keeps it as
`"regression 4031_2"`. A Quint failure ends the session and fails the test
with Quint's output, after the failures found so far; so does a fresh
trace that can't be read (`fresh trace 4031_7 of :counter could not be
read: …`).

Two modules of one model (`traces: :sequential` and `traces: :concurrent`)
each run their own session. Concurrent traces need the same care as the
committed ones: a race the gates don't cover may pass by luck, which the
second replay shows.

### Shrinking

A candidate is as long as the fresh trace up to its failure, and most of
its steps have nothing to do with the bug. A one-step trace is much easier
to debug than a ten-step one, so with `shrink: true` (or
`shrink: [apply: …, import: …, rounds: …]`) in the model's config, explore
shrinks each confirmed candidate before writing it. A confirmed candidate
is one that failed at the same step on the second replay; one that didn't
reproduce, or an adapter exception, isn't shrunk.

```text
counter regression 4031_2, step 1 (Inc), seed 4031: key "counts":
  expected: %{"c1" => 1}
  actual:   %{"c1" => 2}
model step: Inc %{"by" => 1, "ctr" => "c1"}, result :accepted
candidate: _build/test/ash_quint/explore/counter/regression_4031_2.itf.json (cut to 5 steps)
shrunk from 5 to 1 steps (2 rounds)
quint:     npx --yes @informalsystems/quint@0.33.1 run priv/examples/counter/model.qnt … (trace 2)
run:       init.then(inc("c1", 1))
promote:   MIX_ENV=test mix ash_quint.promote _build/test/ash_quint/explore/counter/regression_4031_2.itf.json
```

**How it works.** Dropping a step from the ITF file would leave later
states as the model computed them *with* that step, so shrinking asks
Quint instead. Every pick of a step is in its action value (the model
convention), so the steps rebuild the trace as a Quint run,
`init.then(inc("c1", 2)).then(…)`. Each round:

1. writes a wrapper module that imports the model's `random: [main: …]`
   module, with one run per reduction (a chunk of the steps before the
   failing one removed);
2. runs them all in one `quint test`. A run Quint passes is a valid model
   trace;
3. replays those against the system. The first whose replay still fails
   with the same action, at any step, is kept, cut after that step.

The chunk halves when no reduction is kept, and the loop ends when no
single step can be removed, or after `rounds` rounds (default 20). The
kept trace is replayed once more and must fail with that action at its
last step. A round whose `quint test` writes no runs ends the loop early:
the block adds `stopped:   quint test wrote no runs: <Quint's first line>`
after the `shrunk from` line (or, with nothing kept yet, says
`not shrunk:` with that reason). Shrinking never fails the session: if it
raises, the candidate is written as confirmed
(`not shrunk: shrinking raised: …`).

**How a step becomes a call:**

- **By convention:** the action variant's name with its first letter
  lowercased is the operator, and a record pick's fields, in the order the
  model declares them, are its arguments: `Inc({ ctr: "c1", by: 2 })` is
  `inc("c1", 2)`. A value or map pick is the one argument, and a unit
  variant is called bare (`Reset` is `reset`). The order comes from the
  model interface in the committed manifest, so it needs format 3
  (`mix ash_quint.gen`).
- **`apply:`** names a model action that takes the action value, for a
  model whose operators don't follow the convention:

  ```quint
  action apply(a: Action): bool = match a {
    | Init => init
    | IncStart(r) => incStart(r.op, r.by)
    | IncDone(r) => incDone(r.op)
  }
  ```

  Every call is then `apply(IncStart({ op: "o1", by: 1 }))`.
- **`import:`** is what the wrapper imports from the model file, by
  default the `random: [main: …]` module. A Quint `import` doesn't
  re-export what the imported module imports, so when `main` is an
  instance module that sets the constants, the wrapper finds none of its
  actions (`not shrunk: quint test failed: Error [QNT404]: Name 'init' not
  found`). Name the instance instead:

  ```quint
  module counter_app {
    import counter(CAP = 5).*
  }
  ```

  with `shrink: [import: "counter(CAP = 5)"]`, written in the wrapper as
  `import counter(CAP = 5).* from "<model>"`. Round 0 still checks that the
  runs give back the candidate's states.

**Round 0 checks the mapping.** Before the first round, a run of every
step must give back the candidate's states, variable by variable. When it
doesn't (an operator that isn't found, arguments in another order,
nondeterminism inside an operator rather than in `step`), or a value can't
be written as a Quint literal, the candidate is written as confirmed and
the block says why: `not shrunk: the model's run differs from the trace at
step 3, variable "counts"`.

**What you get.** A shrunk candidate is the kept run's ITF, with `shrunk`
(`rounds`, `run`, `steps`) added to its provenance; its `args` still
regenerate the batch, `steps` counts the full trace, and the failure's
message is its own replay's. So the `quint:` line regenerates the
original, unshrunk trace, and the `run:` line, as a `run` in
`model-tests.qnt`, reproduces the shrunk one. It promotes like any other
candidate, with the batch's seed.

**Cost.** Each round costs one `quint test` (about a second, mostly Node
start-up) plus a replay of each passing run against the system, in the
test's process and sandbox (with `sandbox:`, each in a transaction of its
own). Only failures shrink, and a session stops after `--failures` of
them. The wrapper and its ITF files go in a fresh
`_build/<env>/ash_quint/shrink/<model>_<random>/`, removed afterwards.

A reduction must stay in the module's `traces:` selection, so a shrunk
race isn't promoted as a sequential trace.

## Databases

A concurrent replay reproduces a race only where an op task stops at a
gate, and only if the ops' database work really overlaps. Both depend on
where the gates are and on how the op tasks reach the database. This
section covers both, and the sandbox settings long-running tests need.

### Placing gates

There are three ways, from most precise to least invasive:

1. **Explicit checkpoints.** `AshQuint.Gate.checkpoint/1` in the code, or
   the Ash change `AshQuint.Ash.Gate` in an action:

   ```elixir
   update :inc do
     require_atomic? false
     change MyApp.Counter.Changes.Inc
     change {AshQuint.Ash.Gate, at: :after_read}
   end
   ```

   In an action that isn't atomic, the change gates in a `before_action`
   hook: after every change, inside the action's transaction, right before
   the write. In an atomic action it gates while the changeset is built,
   before the transaction, so the data layer computes the atomic values
   from the row as it is when it writes. This is the most precise option,
   and the most invasive one: the gate lives in the system's code. It
   needs no env guard, though. Where ash_quint isn't enabled, the change
   adds no hook and `checkpoint/1` compiles to `:ok` (see
   [Installation](#installation)).
2. **Telemetry gates**, attached by the adapter. Telemetry handlers run in
   the process that emits the event, so a gate on Ecto's query event stops
   an op task after each of its SQL statements, with no change to the
   system's code:

   ```elixir
   def init(_trace, _opts) do
     AshQuint.Gate.Telemetry.attach([[:my_app, :repo, :query]])
     {:ok, %{}}
   end

   def step(ctx, %Step{action_taken: "IncRead", nondet_picks: %{"op" => op}}),
     do: {:advance, op, ctx, at: {:query, 2}}
   ```

   The replay detaches the gates when it ends, after `finish/2`, also when
   the adapter raises; `detach/1` detaches them earlier.

   Gates are named `{:query, n}` (`n` counted per process); `name: :update`
   names them `{:update, n}`, and a function `(event, metadata, n -> name)`
   names them from the event. Ash's action spans (`[:ash, :my_domain,
   :update, :start]`) work the same way. The handlers are global, but they
   gate only the op tasks of the replay that attached them, so other tests,
   and replays running at the same time, aren't affected. The costs: the
   gate comes after the query, not before it, and counting queries breaks
   when the query plan changes.
3. **Adapter-owned seams**: a behaviour the system already calls (a mail
   client, a payment gateway) whose test implementation calls
   `checkpoint/1`. This is the natural gate for "a retry overlapping a
   commit".

### Sandbox or real connections

Which races you can reproduce depends on how op tasks reach the database:

- **The Ecto sandbox, shared** (the usual `DataCase`, `async: true`). Op
  tasks are allowed through `$callers`, so they all use the test's one
  connection, inside its one wrapping transaction. Statements interleave;
  transactions don't. While an op is inside `Repo.transaction` it holds
  the connection, so if it is gated there, the next op's first query waits
  for the connection, never settles, and the replay fails with a settle
  timeout that names the gate. Races between separate statements or
  separate transactions do reproduce here: a read-modify-write split
  across two transactions loses its update.
- **Real connections** (`async: false`, the sandbox in `:auto` mode). Each
  op task checks out a connection of its own, so isolation levels, row
  locks and deadlocks are real. **Races inside a transaction (row locks,
  isolation anomalies) need this mode.** Every write commits, so:
  - delete what the replay created in `finish/2` (its rows, or its
    tenant); every op task has stopped by then, and an op cancelled inside
    a transaction has rolled it back;
  - scope `project/1` to the trace (see "Scope `project/1` to the trace"):
    the rows of earlier replays and mutants stay committed;
  - tell the replay when an op waits on another's lock: call
    `AshQuint.Ash.pg_backend_pid(Repo)` inside the call, on the
    connection its statements use, and ask Postgres in `blocked?/2`:

    ```elixir
    @impl true
    def blocked?(_ctx, op_info), do: AshQuint.Ash.pg_blocked?(MyApp.Repo, op_info)
    ```

  Other tests that share the database see the committed rows, hence
  `async: false`.
- **A sandbox owner per op task doesn't work:** each op is then inside its
  own uncommitted transaction, sees none of the others' writes, and
  nothing races.

The two modes go in two test modules, with `traces:` splitting the model's
traces (see [The test case](#the-test-case)): the sequential traces in the
async sandbox module, and the concurrent ones in a module that switches
the sandbox to `:auto`:

```elixir
defmodule MyApp.RaceConcurrentTraceTest do
  # No sandbox owner: the sandbox is in :auto mode for this module.
  use ExUnit.Case, async: false

  use AshQuint.Case,
    model: :race,
    adapter: MyApp.RacePgTrace,
    traces: :concurrent,
    sensitivity: [allow_untested: [vars: ~w(inflight finished)]]

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(MyApp.Repo, :auto)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(MyApp.Repo, :manual) end)
  end
end
```

ash_quint's own Postgres tests do this: the race example's adapter over
Postgres,
[`test/support/postgres/race_pg_adapter.ex`](https://github.com/Torkan/ash_quint/blob/main/test/support/postgres/race_pg_adapter.ex),
and its module,
[`test/ash_quint/postgres/race_pg_test.exs`](https://github.com/Torkan/ash_quint/blob/main/test/ash_quint/postgres/race_pg_test.exs).

### One transaction per trace: `sandbox:`

The explore test and the sensitivity test are single tests that replay
many traces: every fresh trace of a session, or every trace and every
mutant. In the usual `DataCase` they all run in the test's one sandbox
transaction, so nothing a trace takes is released until the test ends: its
rows and, with Postgres, every transaction-level lock it took
(`pg_advisory_xact_lock`, row locks).

That can bite. Postgres keeps one lock table for the whole server, about
`max_locks_per_transaction` × `max_connections` entries (6,400 with the
defaults), shared by every database on it. A long enough explore run fills
it, the next statement fails with
`ERROR 53200 (out_of_memory) out of shared memory`, and explore reports
that as a failure of the system, with a `promote:` line for a trace that
fails for no reason of its own. Other test runs on the same server fail
with the same error meanwhile.

`sandbox:` gives each of those replays a transaction of its own:

```elixir
defmodule MyApp.AccessTraceTest do
  use MyApp.DataCase, async: true

  use AshQuint.Case,
    model: :access,
    adapter: MyApp.AccessTrace,
    sensitivity: true,
    explore: true,
    sandbox: MyApp.Repo
end
```

Each explore replay (fresh, confirmation and shrink replays) and each
clean and mutant replay of the sensitivity check then checks out a sandbox
connection (`Ecto.Adapters.SQL.Sandbox.checkout/1`) before `init/2` and
checks it in after `finish/2`, on pass, failure or raise. Checking in
rolls the trace back and releases its rows and locks. Op tasks are allowed
on the replay's connection, in `:manual` and in shared mode. Other
processes the system starts reach it through `$callers` in `:manual` mode,
which is what the template clause below leaves; in shared mode (a template
that starts a shared owner for these tests too) they would reach the
shared owner's connection instead. The trace tests don't use the option:
they replay in the template's sandbox, as before.

The test process must have no connection of its own for this, so the case
template has to skip its sandbox setup for the two tests:

```elixir
setup tags do
  setup_sandbox(tags)
  :ok
end

defp setup_sandbox(%{quint_explore: _}), do: :ok
defp setup_sandbox(%{quint_sensitivity: _}), do: :ok

defp setup_sandbox(tags) do
  pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MyApp.Repo, shared: not tags[:async])
  on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
end
```

Without that clause, the test owns (or is allowed on) the template's
connection, and the explore or sensitivity test fails at once, before its
first replay, with a message naming the clause to add. A replay called
directly (`AshQuint.Replay.run/3` with `sandbox:`) from a process that
already has a connection takes none and gives none back. The pool's
ownership timeout then applies to one trace, not to the whole session.
`sandbox:` needs `ecto_sql`; without it, ash_quint calls no Ecto function.

## CI

- **The default test suite needs neither Node nor Quint.** Run
  `mix test --warnings-as-errors`, so the adapter check's warnings (see
  "The test case") fail the build.
- **Exploring isn't meant for CI by default:** it tries new traces each
  run, so a failure depends on the seed. Run it locally, or in a scheduled
  job with Node (`MIX_ENV=test mix ash_quint.explore --budget 600`), and
  promote what it finds.
- **Check the traces are current.** In a job with Node, run
  `MIX_ENV=test mix ash_quint.gen --check`. It regenerates every model's
  traces and fails if they differ from the committed ones, so a model
  change without regenerated traces, or a change in Quint's output, is
  caught. It needs the model files, so with `on_missing_model: :skip` and
  models that aren't committed it fails in CI; run it where the models are
  instead, or name only the committed models
  (`mix ash_quint.gen counter --check`).

## Limitations

- **Concurrent replay controls only what reaches a gate.** Gate releases
  happen in the order the trace says, no op passes a gate before the step
  that releases it, and the state is never projected while an op is
  between gates. What happens between two gates (BEAM scheduling, the
  database's locks, `after_action` hooks, jobs sent after a commit) isn't
  controlled: if a race window has no gate, the replay may pass by luck,
  and a trace is deterministic only when its gates cover every racing
  point.
- Blocked ops are detected by `blocked?/2` (for Postgres,
  `AshQuint.Ash.pg_blocked?/2`) or else by timeout (`may_block: true`),
  which is timing-based.
- Processes that don't carry `$callers` back to an op task (a GenServer
  the call sends work to, say) aren't gated.
- Op tasks are separate processes: private ETS tables and per-process
  state aren't shared with them. With the Ecto sandbox in shared mode they
  all use the test's connection and its one transaction, so races inside
  transactions (row locks, isolation anomalies) need real connections (see
  [Databases](#databases)).
- The sandbox transaction a replay checks out with `sandbox:` is rolled
  back when the replay ends, but checking in returns before the rollback
  has run: the next replay may briefly see the previous one's locks.
- `random:` takes no invariants to check; any non-zero exit of
  `quint run` fails generation.
- Model integers are limited to the signed 64-bit range by Quint's Rust
  backend; larger ones need `backend: "typescript"`.

## License

MIT; see `LICENSE`.
