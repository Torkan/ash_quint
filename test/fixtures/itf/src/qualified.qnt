// Decoder fixture: a quint test trace with module-qualified variable names.
// Quint 0.33.1 qualifies names only for instanced imports, hence the const.
// Regenerate test/fixtures/itf/qualified.itf.json from the repo root with
//   npx --yes @informalsystems/quint@0.33.1 test test/fixtures/itf/src/qualified.qnt \
//     --main=tests --match='Test$' --seed=1 \
//     --out-itf='test/fixtures/itf/qualified_{test}_{seq}.itf.json'
// then rename qualified_incTest_0.itf.json to qualified.itf.json and delete
// "description" and "timestamp" from the top-level "#meta".
module counterP {
  type Action = Init | Inc
  type Result = Accepted | Rejected(str)

  const MAX: int

  var count: int
  var lastAction: Action
  var lastResult: Result

  action init = all {
    count' = 0,
    lastAction' = Init,
    lastResult' = Accepted,
  }

  action inc = all {
    lastAction' = Inc,
    if (count < MAX) all {
      count' = count + 1,
      lastResult' = Accepted,
    } else all {
      count' = count,
      lastResult' = Rejected("over_limit"),
    },
  }
}

module tests {
  import counterP(MAX = 3) as model

  run incTest = model::init.then(model::inc).then(model::inc)
}
