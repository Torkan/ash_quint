# Rules for working with ash_quint

ash_quint replays the traces of a Quint model against the real system in
ExUnit. Quint generates the traces once (`mix ash_quint.gen`); they are
committed; `AshQuint.Case` turns each into a test that runs it through an
adapter (`AshQuint.Adapter`) and compares outcomes, state and invariants
after every step. The README is the full guide.

Sub-rules:

- [modeling](usage-rules/modeling.md) (`ash_quint:modeling`): writing and
  checking the Quint model.
- [adapters](usage-rules/adapters.md) (`ash_quint:adapters`): writing the
  adapter and reading failures.

## The model convention

- Every action, `init` included, sets `lastAction` to a variant of a sum
  type: the tag is the action's name, the value holds its nondeterministic
  picks (a record, one value, or nothing: `Inc({ ctr: "c1", by: 2 })`,
  `Reset("c1")`, `Init`).
- `lastResult`, when present, is `Accepted` or `Rejected(code)`; the replay
  asserts the system's outcome against it. `Pending` marks a call still in
  flight (start and completion actions over an `op` field).
- Every other variable is model state the adapter's projection is compared
  with. Keep values small and finite; map them to real ones with
  `AshQuint.Names`.
- Model integers must fit in 64 bits on Quint's default `rust` backend.
  Pin `backend: "typescript"` for a model that needs larger integers.

## The workflow

1. Configure the model in `ash_quint.exs` at the project root: `quint:`
   (the pinned Quint version), `backend:`, and per model a `seed:` and at
   least one of `random:`, `witnesses:` and `scenarios:`.
2. Run `MIX_ENV=test mix ash_quint.gen` and commit the traces and
   `manifest.json` it writes.
3. Run `MIX_ENV=test mix ash_quint.gen.adapter <model>` once for the
   adapter skeleton and its test module, then fill in the adapter (see the
   adapters sub-rules).
4. The test module: `use AshQuint.Case, model: :<model>, adapter: …,
   sensitivity: true`. Keep `sensitivity: true`; allow-list only what is
   deliberately untested.
5. Add `explore: true` and run `MIX_ENV=test mix ash_quint.explore` to
   replay fresh traces; commit a failure it finds, after fixing the bug,
   with `MIX_ENV=test mix ash_quint.promote <candidate>`.
6. In CI, run `mix test --warnings-as-errors` (the adapter check warns at
   compile time), and `MIX_ENV=test mix ash_quint.gen --check` in a job
   with Node.

## Rules

- Never edit generated traces or `manifest.json` by hand. Change the model
  or the config and rerun `mix ash_quint.gen`; drop a regression trace by
  deleting its file and rerunning it.
- After changing a model file, regenerate: the `traces for <model> are
  current` test fails until you do.
- Pin the Quint version (`quint:`) and the backend (`backend:`); both
  change the traces.
- The default test suite must not need Node or Quint: only `mix
  ash_quint.gen`, `mix ash_quint.explore` and `mix ash_quint.promote` run
  Quint or write traces. Exclude `:quint_explore` in
  `test/test_helper.exs` (`ExUnit.start(exclude: [:quint_explore])`).
- Depend on ash_quint with `only: [:dev, :test]`: with `only: :test`,
  `mix usage_rules.sync` (which runs in dev) doesn't find these rules. Its
  Mix tasks run under `MIX_ENV=test` (or set `preferred_envs` in
  `mix.exs`).
- Model names, action names, picks and variable names stay strings in
  Elixir; don't turn trace data into atoms.
