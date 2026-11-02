# ash_quint's own config: the counter example in priv/examples/counter.
# Regenerate its traces with `MIX_ENV=test mix ash_quint.gen counter`.
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
    ]
  ]
]
