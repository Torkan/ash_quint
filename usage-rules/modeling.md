# Writing the Quint model for ash_quint

The practices behind these rules, with their sources, are in the README's
"Modelling practices".

## Rules

- Model what the code does, bugs included, and change the model together
  with the code. Regenerate with `mix ash_quint.gen` after every model
  change.
- One named invariant per property, so a violation's trace is short and
  says what broke. Mirror them in the adapter's `invariants/0`.
- For a stored or cached value, add a storage-consistency invariant: the
  stored value against the one recomputed from its source. In Ash, check a
  stored attribute against an aggregate or calculation over its source,
  in an adapter invariant that loads both.
- Check that an invariant is specific: run a step without the buggy path
  and expect no violation, and a deliberately over-faulty one and expect a
  violation (`quint run model.qnt --invariant=<inv> --step=<variant>`).
  ash_quint's `random:` takes no invariant; run these yourself.
- Write honest and malicious (or faulty) actions side by side, as
  separate step actions; `random: [step: …]` and `witnesses: [step: …]`
  choose the one the traces come from.
- Model failures (restarts, crashes, lost writes) as actions in the
  `Action` type; the adapter makes them happen.
- One witness per key scenario: a `val` that becomes true when the
  scenario is reached (`val witOverLimit = lastResult ==
  Rejected("over_limit")`), listed in `witnesses: [names: …]`. Explore
  reports how often fresh traces reach each one; `never` means the random
  traces don't test that scenario.
- Concrete scenarios are `run` tests in `model-tests.qnt`, configured under
  `scenarios:`. A shrunk explore candidate prints its steps as a run
  (`run:       init.then(inc("c1", 1))`); paste it into `model-tests.qnt`
  to keep the failure as a scenario as well as a regression trace. Its
  `quint:` line regenerates the original, unshrunk trace, not this run.
- To let explore shrink its candidates (`shrink: true`), keep every pick
  of a step in its action value and name each step action after its
  variant: `Inc({ ctr: "c1", by: 2 })` is called as `inc("c1", 2)`, the
  variant's name with its first letter lowercased, with the record's
  fields in their declared order as arguments; a value or map pick is the
  one argument, and a unit variant is called bare. A model whose actions
  don't fit adds `action apply(a: Action): bool = match a { … }` and sets
  `shrink: [apply: "apply"]`. Keep nondeterminism in `step`, not inside
  the actions: shrinking checks that the calls give back the candidate's
  states first, and doesn't shrink when they don't.
- With concurrency, model what the system visibly shows: the replay
  compares state while calls are in flight, so uncommitted writes don't
  belong in projected variables.
- `set`, `get` and `next` are reserved in Quint 0.33.1 and can't name a
  variable or action.

## Quint commands

Run Quint through the pinned version, from the project root, with model
paths relative to it (Quint writes the path into the traces):

```sh
npx --yes @informalsystems/quint@0.33.1 typecheck test/quint/counter/model.qnt
npx --yes @informalsystems/quint@0.33.1 test test/quint/counter/model-tests.qnt --main=tests
npx --yes @informalsystems/quint@0.33.1 run test/quint/counter/model.qnt --main=counter \
  --invariants countsWithinLimit writesNonNegative --witnesses witOverLimit witResetAfterInc
```

All three must pass before the traces are generated and the adapter is
trusted: an agent may draft the model, but only these, the replays and
the sensitivity check decide whether it is right.
