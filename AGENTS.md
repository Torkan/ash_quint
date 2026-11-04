# AGENTS.md

Guide for coding agents working on ash_quint.

## Gates

Every change must leave these green:

```sh
mix format --check-formatted
mix credo --strict
mix compile --force --warnings-as-errors
mix test
mix dialyzer
mix docs            # no warnings
```

Also, when traces, the example or packaging change:

```sh
mix compile --force --warnings-as-errors   # with MIX_ENV=test too
mix test --only quint_cli                  # needs Node
MIX_ENV=test mix ash_quint.gen --check     # needs Node
mix hex.build                              # no test/, config/, agent-plans/
                                           # or root ash_quint.exs in the files
```

## Module map

- `AshQuint` (`lib/ash_quint.ex`) — overview; the README is the user guide.
- `AshQuint.ITF`, `AshQuint.Trace`, `AshQuint.Step` — ITF decoding, traces,
  steps.
- `AshQuint.Adapter`, `AshQuint.Names`, `AshQuint.Replay` — the adapter
  behaviour and the replay.
- `AshQuint.Sensitivity` — mutants and untested keys and actions.
- `AshQuint.Config`, `AshQuint.Manifest`, `AshQuint.Gen`,
  `Mix.Tasks.AshQuint.Gen` — `ash_quint.exs`, the manifest and
  `mix ash_quint.gen`.
- `AshQuint.Coverage`, `Mix.Tasks.AshQuint.Coverage` — the action × outcome
  table of the committed manifests, `mix ash_quint.coverage` (also printed
  by `mix ash_quint.gen` after writing).
- `AshQuint.Case` — compile-time test generation.
- `AshQuint.Ash` — Ash helpers, compiled only when Ash is loaded; no other
  module in `lib/` may call Ash (`core_has_no_ash_test`).
- `priv/examples/counter/` — the example model and its committed traces
  (configured in the root `ash_quint.exs`, which isn't packaged).
  Regenerate with `MIX_ENV=test mix ash_quint.gen counter`.
- `priv/examples/race/` — the concurrency example (start/complete actions
  over op ids, `Pending` results) and its committed traces, configured in
  the root `ash_quint.exs` too. It has no adapter yet: concurrent replay
  isn't implemented, and `race_example_test` checks that its traces are
  refused. Regenerate with `MIX_ENV=test mix ash_quint.gen race`.
- `test/support/counter_adapter.ex` — the reference adapter, linked from the
  README; `test/support/toy_adapter.ex` — an in-memory adapter with
  switchable faults for the Replay and Sensitivity tests.

## Quint

- The default suite excludes `:quint_cli`-tagged tests and must never need
  Node or Quint. Run the tests that call real Quint (needs Node) with
  `mix test --only quint_cli`. Don't tag them `:quint`: `AshQuint.Case` tags
  its replay tests `quint: <source>`, and those run in the default suite.
- Quint is pinned to 0.33.1 and run through npx, from the repo root:
  `npx --yes @informalsystems/quint@0.33.1 <run|test> …`. In zsh, put the
  command in an array (`Q=(npx --yes @informalsystems/quint@0.33.1)`), since a
  string isn't word-split.
- Pass model paths relative to the repo root: Quint writes the path into
  `#meta.source`.

## Rules

- **Elixir floor is ~> 1.17** (Ash 3 requires it), even when developing on a
  newer Elixir: use no APIs newer than 1.17 (no `JSON` module). Use `Jason`
  for JSON.
- **No atoms from trace data:** model names, tags and keys stay strings.
- Every public module and function gets `@moduledoc`/`@doc` and a `@spec`.
- **Off-limits:** never edit, stage or commit `mise.toml` or `mise.local.toml`.
