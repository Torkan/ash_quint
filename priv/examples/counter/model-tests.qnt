// Scenario tests for the counter example model.
module tests {
  import counter.* from "./model"

  run incTest = init
    .then(inc("c1", 2))
    .expect(counts.get("c1") == 2 and writes.get("c1") == 1 and lastResult == Accepted)

  run overLimitTest = init
    .then(inc("c1", 2))
    .then(inc("c1", 2))
    .expect(counts.get("c1") == 2 and lastResult == Rejected("over_limit"))

  run resetTest = init
    .then(inc("c2", 1))
    .then(reset("c2"))
    .expect(counts.get("c2") == 0 and writes.get("c2") == 2 and lastAction == Reset("c2"))
}
