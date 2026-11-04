// Scenario tests for the race example model.
module tests {
  import race.* from "./model"

  // o1 and o2 both start before either returns; o2 returns first.
  run raceTest = init
    .then(incStart("o1", 2))
    .then(incStart("o2", 2))
    .then(incDone("o2"))
    .then(incDone("o1"))
    .expect(count == 2 and writes == 1 and lastResult == Rejected("over_limit"))
}
