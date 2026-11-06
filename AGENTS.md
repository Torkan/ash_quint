# AGENTS.md

Guide for coding agents working on ash_quint.

## Gates

Every change must leave these green:

```sh
mix format --check-formatted
mix credo --strict
mix compile --force --warnings-as-errors
mix test --warnings-as-errors   # the adapter check warns while test files compile
mix dialyzer
mix docs            # no warnings
mix usage_rules.validate usage-rules.md usage-rules/*.md
```

Also, when traces, the example or packaging change:

```sh
mix compile --force --warnings-as-errors   # with MIX_ENV=test too
mix test --only quint_cli                  # needs Node
MIX_ENV=test mix ash_quint.gen --check     # needs Node
mix hex.build                              # lists usage-rules.md and usage-rules/;
                                           # no test/, config/, agent-plans/, models/,
                                           # priv/test_repo, priv/resource_snapshots
                                           # or root ash_quint.exs in the files
```

When the Postgres tests, the Gate, the replay or `AshQuint.Ash` change:

```sh
mix test --only postgres                   # needs Postgres; see "Postgres"
mix test.check_migrations
```

When `AshQuint.Shrink.Loop` or `models/practices/` change (needs Node; `$Q`
as in "Quint"):

```sh
$Q typecheck models/practices/model.qnt
$Q test models/practices/model-tests.qnt --main=tests --match='Test$'   # 4 passing
$Q run models/practices/model.qnt --main=shrink6 --max-steps=30 --max-samples=10000 --seed=1 \
  --invariants keptValid keptFails keptOrdered chunkBounded doneMinimal roundsBounded
```

## Module map

- `AshQuint` (`lib/ash_quint.ex`) — overview; the README is the user guide.
- `AshQuint.ITF`, `AshQuint.Trace`, `AshQuint.Step` — ITF decoding, traces,
  steps.
- `AshQuint.Adapter`, `AshQuint.Names`, `AshQuint.Replay` — the adapter
  behaviour (`project/1` optional; `postconditions/0`, checked after the
  state comparison and the invariants) and the replay;
  `AshQuint.Replay.Ops` (internal) — the ops in flight during a concurrent
  replay; `AshQuint.Diff` (internal) — the
  differing entries of a long key mismatch.
- `AshQuint.Gate` — gates (`checkpoint/1`, `put_info/2`,
  `current_replay/0`) and the op-task primitives;
  `AshQuint.Application` starts `AshQuint.Gate.Table`, the ETS table that
  registers op tasks. `AshQuint.Gate.Telemetry` — telemetry gates scoped to
  a replay, compiled only when `:telemetry` is loaded (optional dep).
- `AshQuint.Sensitivity` — mutants (perturbed key, dropped call or op
  start/completion, serialized op) and untested keys, actions,
  interleavings and unprojected model variables; `overlaps/1` over a
  replay report.
- `AshQuint.Interface` — the model interface (actions and their picks,
  results, vars) read from `quint compile --target=json` and recorded in
  the manifest (format 3). Its tests read the JSON IR fixtures in
  `test/fixtures/quint_ir/` (`counter.json`, `race.json`,
  `counter_tests.json`), captured from Quint 0.33.1. Recapture them with
  `--out`, not by redirecting stdout (which truncates), e.g.
  `$Q compile --target json --main=counter priv/examples/counter/model.qnt
  --out=test/fixtures/quint_ir/counter.json` (`--main=race` for
  `priv/examples/race/model.qnt`, `--main=tests` for
  `priv/examples/counter/model-tests.qnt`).
- `AshQuint.Config`, `AshQuint.Manifest`, `AshQuint.Gen`,
  `Mix.Tasks.AshQuint.Gen` — `ash_quint.exs`, the manifest and
  `mix ash_quint.gen` (which keeps `regression_*.itf.json` files as they
  are; provenance helpers in `AshQuint.Gen`).
- `Mix.Tasks.AshQuint.Promote` — `mix ash_quint.promote`: commits explore
  candidates as regression traces (source `regression`, per-entry `seed`).
- `AshQuint.Coverage`, `Mix.Tasks.AshQuint.Coverage` — the action × outcome
  table of the committed manifests, `mix ash_quint.coverage` (also printed
  by `mix ash_quint.gen` after writing).
- `AshQuint.Case` — compile-time test generation;
  `AshQuint.Case.AdapterCheck` (internal) — the compile-time check of the
  adapter's `step/2` clauses (from its debug info) against the manifest's
  interface, warning at the `use` line. Its fixture adapters are in
  `test/support/adapter_check_fixtures.ex` (compiled to beams, so they
  carry debug info).
- `AshQuint.Scaffold`, `Mix.Tasks.AshQuint.Gen.Adapter` — the adapter
  skeleton and test module source from a manifest's interface,
  `mix ash_quint.gen.adapter` (writes `test/support/<model>_trace.ex` and
  `test/<model>_trace_test.exs`).
- `AshQuint.Explore`, `Mix.Tasks.AshQuint.Explore` — explore sessions
  (fresh `quint run` traces replayed, failures written as candidates under
  `_build/<env>/ash_quint/explore/`), the `explore:` test and
  `mix ash_quint.explore`.
- `AshQuint.Shrink` — shrinking explore candidates (`shrink:`): rendering
  ITF values as Quint, a trace's steps as calls, the wrapper module and
  the driver `shrink/3` (round 0, the rounds through `quint test`, the
  final confirmation); `AshQuint.Shrink.Loop` (internal) — the loop's
  state machine, mapped 1:1 to `models/practices/model.qnt` (its
  `quint_cli` test replays the model's traces against it). Fixtures:
  `test/fixtures/case/shrink/` (the `:shrink` model of
  `test/fixtures/case/ash_quint.exs`: a format 3 manifest, a shrunk
  regression and, in `batch/`, an explore trace that shrinks) and
  `test/fixtures/shrink/race_apply/model.qnt` (the race model with an
  `apply` action, for `shrink: [apply: "apply"]`).
- `models/practices/` — the shrink loop's Quint model and its tests (a
  spec artefact, not an example; not packaged, not in `ash_quint.exs`;
  mirrored in Redline `ash_quint/practices/model`). Its commands are in
  "Gates".
- `AshQuint.Ash`, `AshQuint.Ash.Gate` — Ash helpers (outcomes, snapshots,
  tracer context transfer, `pg_backend_pid/1`, `pg_blocked?/2`) and the
  gate change, compiled only when Ash is loaded; no other module in `lib/`
  may call Ash (`core_has_no_ash_test`, which skips every `AshQuint.Ash.*`).
- `priv/examples/counter/` — the example model and its committed traces
  (configured in the root `ash_quint.exs`, which isn't packaged; both
  examples have `shrink: true`).
  Regenerate with `MIX_ENV=test mix ash_quint.gen counter`.
- `priv/examples/race/` — the concurrency example (start/complete actions
  over op ids, `Pending` results) and its committed traces, configured in
  the root `ash_quint.exs` too. Its adapter is `test/support/race_adapter.ex`
  (against `test/support/ash/race_counter.ex`, a non-private ETS resource).
  Regenerate with `MIX_ENV=test mix ash_quint.gen race`.
- `test/support/counter_adapter.ex` — the reference adapter, linked from the
  README, and `CounterAdapterOffByOne`, a broken one for the failure and
  explore tests; `test/support/toy_adapter.ex` — an in-memory adapter with
  switchable faults for the Replay and Sensitivity tests, plus
  `PostconditionToyAdapter` (no `project/1`, postconditions, faults
  `:blind_post` and `:raising_post`) for the light-adapter tests;
  `test/support/concurrent_toy_adapter.ex` — its concurrent counterpart
  (an Agent-backed counter, gates and a lock) for the concurrent replay
  tests, plus `ConcurrentToyAdapterBlind`, whose projection is blind until
  completion, for the serialization mutant.
- `test/support/test_repo.ex` (`AshQuint.TestRepo`) and
  `test/support/postgres/` — the Postgres test setup: `PgDomain`,
  `PgRaceCounter` (the race resource over Postgres), `RacePgAdapter` (the
  race example unboxed), `PgOpsAdapter` (per-op calls, for the sandbox
  tests) and `DataCase` (`async: true` for the shared sandbox,
  `unboxed: true` for real connections). Tests in `test/ash_quint/postgres/`.
- `usage-rules.md`, `usage-rules/modeling.md`, `usage-rules/adapters.md` —
  the packaged usage rules (`ash_quint`, `ash_quint:modeling`,
  `ash_quint:adapters`), checked by `mix usage_rules.validate`; keep them
  in step with the README (its "Modelling practices" cites the sources).

## Quint

- The default suite excludes `:quint_cli`-tagged tests and must never need
  Node or Quint. Run the tests that call real Quint (needs Node) with
  `mix test --only quint_cli`. Don't tag them `:quint`: `AshQuint.Case` tags
  its replay tests `quint: <source>`, and those run in the default suite.
- `:quint_explore` tags the explore tests (`explore: true` in the examples'
  test modules); `test_helper.exs` excludes it and it must never run in the
  default suite. Run them with `MIX_ENV=test mix ash_quint.explore`.
- Quint is pinned to 0.33.1 and run through npx, from the repo root:
  `npx --yes @informalsystems/quint@0.33.1 <run|test> …`. In zsh, put the
  command in an array (`Q=(npx --yes @informalsystems/quint@0.33.1)`), since a
  string isn't word-split.
- Pass model paths relative to the repo root: Quint writes the path into
  `#meta.source`.

## Postgres

- The default suite excludes `:postgres`-tagged tests and must never need
  Postgres. Run them with `mix test --only postgres`; `test_helper.exs`
  starts `AshQuint.TestRepo` only then.
- The database is the developer's own Postgres on localhost (user and
  password `postgres`; `POSTGRES_PORT`, default 5432;
  `POSTGRES_TEST_DATABASE`, default `ash_quint_test`). Set it up with
  `mix test.create` and `mix test.migrate`; `mix test.reset` drops and
  recreates it.
- Migrations are generated from the resources, never hand-written: after
  changing a Postgres resource, run `mix test.generate_migrations --name …`
  and commit `priv/test_repo/migrations` and
  `priv/resource_snapshots/test_repo` (neither is packaged).
  `mix test.check_migrations` fails when they are out of date.
- `ash_postgres` is a test-only dependency: `mix format` in dev can't
  import its formatter config, so `.formatter.exs` lists its DSL's
  `locals_without_parens`.

## Rules

- **Elixir floor is ~> 1.17** (Ash 3 requires it), even when developing on a
  newer Elixir: use no APIs newer than 1.17 (no `JSON` module). Use `Jason`
  for JSON. The floor applies to `lib/` and the test env; dev-only tools
  may need newer Elixir (`usage_rules` needs ~> 1.18, so CI validates the
  usage rules only in the 1.20 job's dev steps).
- **Checking another Elixir (e.g. the 1.17 floor):** never run
  `mix local.hex` or `mix local.rebar`, and don't rely on
  `mise exec elixir@…`. mise exports `MIX_HOME` and `MIX_ARCHIVES` for the
  active Elixir, and in an activated shell `mise exec` changes `MIX_HOME`
  but leaves the active `elixir` first on `PATH`. A mixed toolchain then
  writes one version's archives with another's OTP, which breaks Hex for
  every mix task. Set all four explicitly, in a scratch copy of the repo,
  and check `elixir --version` first:

  ```sh
  I=$HOME/.local/share/mise/installs
  env PATH="$I/elixir/1.17.3-otp-27/bin:$I/erlang/27.3.4.3/bin:$PATH" \
    MIX_HOME="$I/elixir/1.17.3-otp-27/.mix" \
    MIX_ARCHIVES="$I/elixir/1.17.3-otp-27/.mix/archives" \
    sh -c 'elixir --version && MIX_ENV=test mix test --warnings-as-errors'
  ```
- **No atoms from trace data:** model names, tags and keys stay strings.
- Every public module and function gets `@moduledoc`/`@doc` and a `@spec`.
- **Off-limits:** never edit, stage or commit `mise.toml` or `mise.local.toml`.
