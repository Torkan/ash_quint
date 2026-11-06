// Scenario tests for the explore shrink loop (spec ash_quint/practices, 1.3).
module tests {
  import shrink(N = 6, MAX_ROUNDS = 50).* from "./model"

  // step stutters once the loop is done.
  // Nothing is needed but the failing step: the loop removes every other step.
  run aloneTest = initWith(Set(), Set())
    .then(step).then(step).then(step).then(step).then(step)
    .then(step).then(step).then(step)
    .expect(done and kept == [5] and not(exhausted))

  // A completion needs its start (IncDone needs IncStart): step 5 needs 2;
  // the failure needs step 0. The loop keeps exactly 0, 2 and 5.
  run dependencyTest = initWith(Set((2, 5)), Set(0))
    .then(step).then(step).then(step).then(step).then(step)
    .then(step).then(step).then(step)
    .expect(done and kept == [0, 2, 5])

  // A chain of dependencies: nothing can go; the loop ends at chunk 1.
  run chainTest = initWith(Set((0, 1), (1, 2), (2, 3), (3, 4), (4, 5)), Set())
    .then(round).then(round)
    .expect(done and kept == [0, 1, 2, 3, 4, 5] and chunk == 1)

  // The first round removes the first chunk of 2 (steps 0 and 1).
  run firstChunkTest = initWith(Set(), Set(2, 3, 4))
    .then(round)
    .expect(kept == [2, 3, 4, 5] and chunk == 2 and not(done))
}
