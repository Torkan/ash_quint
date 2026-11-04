# ash_quint's own config: the examples in priv/examples. Regenerate their
# traces with `MIX_ENV=test mix ash_quint.gen counter` (or `race`).
[
  quint: "0.33.1",
  models: [
    counter: [
      model: "priv/examples/counter/model.qnt",
      tests: "priv/examples/counter/model-tests.qnt",
      out: "priv/examples/counter/traces",
      seed: 20_261_102,
      random: [main: "counter", n_traces: 4, max_steps: 10, max_samples: 20],
      witnesses: [
        main: "counter",
        names: ~w(witOverLimit witResetAfterInc),
        max_steps: 10,
        max_samples: 10_000
      ],
      scenarios: [main: "tests", match: "Test$"]
    ],
    # Two concurrent Incs against a limit: see the README's model convention.
    race: [
      model: "priv/examples/race/model.qnt",
      tests: "priv/examples/race/model-tests.qnt",
      out: "priv/examples/race/traces",
      seed: 20_261_104,
      random: [main: "race", n_traces: 4, max_steps: 10, max_samples: 20],
      witnesses: [main: "race", names: ~w(witOverlap), max_steps: 10, max_samples: 10_000],
      scenarios: [main: "tests", match: "Test$"]
    ]
  ]
]
