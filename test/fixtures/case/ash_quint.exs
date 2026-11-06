# Config for the AshQuint.Case tests. Each model's files live in
# test/fixtures/case/<name>/; the traces are hand-written toy-counter traces.
model = fn name, extra ->
  dir = "test/fixtures/case/#{name}"

  [model: "#{dir}/model.qnt", out: dir, seed: 7, scenarios: [main: "tests"]] ++ extra
end

[
  quint: "0.33.1",
  models: [
    ok: model.(:ok, random: [main: "toy", max_steps: 3]),
    stale: model.(:stale, []),
    missing_fail: model.(:missing_fail, []),
    missing_skip: model.(:missing_skip, on_missing_model: :skip),
    no_manifest: model.(:no_manifest, []),
    empty: model.(:empty, []),
    concurrent: model.(:concurrent, []),
    promoted: model.(:promoted, []),
    # A format 3 manifest and a shrunk regression; batch/ has an explore
    # trace whose leading Resets shrink away.
    shrink: model.(:shrink, random: [main: "toy", max_steps: 3], shrink: true)
  ]
]
