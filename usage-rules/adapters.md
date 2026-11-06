# Writing an ash_quint adapter

An adapter implements `AshQuint.Adapter` for one model. Start from
`mix ash_quint.gen.adapter <model>`, which writes a `step/2` clause per
action binding its picks and a `project/1` with every model variable.

## Rules

- One `step/2` clause per model action, matching a literal
  `action_taken` and the action's picks in `nondet_picks`. Return
  `{:ok, result, ctx}` after a system call, `{:skip, ctx}` for a
  model-only step, and `{:start, op, call, ctx}` / `{:complete, op, ctx}`
  for calls that stay in flight. `AshQuint.Case` warns at compile time
  about a clause for an action the model doesn't have, a pick the action
  doesn't have, and an action without a clause; `mix test
  --warnings-as-errors` makes those failures. Fix the adapter, don't
  silence the warning.
- Map the model's small values to real ones with `AshQuint.Names.fetch/4`
  and back with `AshQuint.Names.reverse/3`.
- Scope `project/1` to the trace: the sensitivity check runs every trace
  and mutant in one test, so read only what this trace created (a tenant
  from `init/2`, the ids kept in `ctx`). Release what a replay holds open
  in `finish/2`.
- `outcome/1` maps the system's errors to the model's rejection codes
  (`AshQuint.Ash.outcome/2` with `codes:`).
- Transition invariants keep what they compare against in `ctx`, from
  `step/2`: an invariant sees only the projection and `ctx`.

## Light adapters and postconditions

- `project/1` is optional. A light adapter leaves it out and checks what
  each step promises with `postconditions/0`: `{name, fun}` pairs where
  `fun.(ctx, step)` returns `:ok` or `{:error, message}`, run after every
  synced step.
- Without `project/1`, no key is compared, and the sensitivity check
  tries no perturbed key and no variable check. With postconditions, each
  action none of whose calls changes the projected state (without
  `project/1`, every action) gets a dropped-call mutant at its first
  accepted call: a postcondition that notices the missing effect makes the
  action tested; one that doesn't is reported, and the action stays
  untested.
- An adapter with neither `project/1` nor postconditions checks outcomes
  and invariants only.

## Concurrency

- Make the call do the read: fetch the record inside `call`, not in
  `step/2`, so it happens in the op task, between gates.
- Place gates where the race happens: `AshQuint.Gate.checkpoint/1` in the
  code path, the Ash change `AshQuint.Ash.Gate`, or
  `AshQuint.Gate.Telemetry.attach/1`. A race window without a gate may
  pass by luck.
- Op tasks are other processes: use tables and sandboxes they can see.
  Races inside a transaction need real database connections
  (`async: false`), with `finish/2` deleting what the replay committed.
- For Postgres locks, record `AshQuint.Ash.pg_backend_pid/1` inside the
  call and define `blocked?/2` with `AshQuint.Ash.pg_blocked?/2`.

## Sensitivity

- Keep `sensitivity: true`. Every allow-list entry
  (`sensitivity: [allow_untested: [keys: …, actions: …, interleavings: …,
  vars: …]]`) is a deliberate statement that something is untested on
  purpose: a constant set up in `init`, in-flight bookkeeping the system
  doesn't have. First check whether a witness or scenario would test it.
- An allow-listed entry that becomes tested fails the check, so remove it
  when it does.

## Reading failures

- A failure starts `<model> <source> <name>, step <i> (<action>), seed
  <seed>: `, lists every problem of that step, then `model step:` (the
  model's picks and result), `trace:` and, for a found trace, `quint:`,
  the command that regenerates it, and for a shrunk one `run:`, its steps
  as a Quint run. A shrunk trace's `quint:` line regenerates the batch's
  original, unshrunk trace; only its `run:` line is the shrunk one.
- Decide whether the system or the model is wrong before changing either.
  A failure in an explore candidate is a bug to fix, then a trace to
  promote with `mix ash_quint.promote`.
