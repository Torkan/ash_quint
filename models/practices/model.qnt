// The explore shrink loop (spec ash_quint/practices, section "1. Shrinking").
//
// A candidate is the list of its steps' positions 0..N-1 (the trace's steps
// 1..N; the initial state is never removed); the last one is the failing
// step and is always kept. Two oracles stand in for Quint and the
// replay, chosen once per behaviour:
//   * valid(s): Quint accepts the run of the calls in s (a step j needs the
//     steps i with (i, j) in deps, as IncDone needs its IncStart);
//   * fails(s): the replay of that run fails with the original failing
//     action (here: s keeps every step of `bad`).
// The loop removes contiguous chunks of the kept prefix, largest first, and
// accepts the first removal that is valid and fails (spec 1.3).
module shrink {
  const N: int
  const MAX_ROUNDS: int

  pure val POSITIONS = 0.to(N - 1)
  pure val PAIRS = tuples(POSITIONS, POSITIONS).filter(p => p._1 < p._2)

  var deps: Set[(int, int)]
  var bad: Set[int]
  var kept: List[int]
  var chunk: int
  var done: bool
  var rounds: int
  var exhausted: bool

  pure def toSet(l: List[int]): Set[int] = l.foldl(Set(), (acc, x) => acc.union(Set(x)))

  pure def validIn(d: Set[(int, int)], s: List[int]): bool =
    d.forall(p => toSet(s).contains(p._2) implies toSet(s).contains(p._1))

  pure def failsIn(b: Set[int], s: List[int]): bool =
    b.subseteq(toSet(s)) and s.length() > 0 and s[s.length() - 1] == N - 1

  // Remove positions [from, from + c) of the prefix (never the last step).
  pure def removeChunk(s: List[int], from: int, c: int): List[int] = {
    val prefix = s.length() - 1
    val upto = if (from + c > prefix) prefix else from + c
    s.slice(0, from).concat(s.slice(upto, s.length()))
  }

  pure def starts(s: List[int], c: int): List[int] = {
    val prefix = s.length() - 1
    // 0, c, 2c, ... below prefix
    range(0, N).select(k => k * c < prefix).foldl([], (acc, k) => acc.append(k * c))
  }

  // The first accepted removal at chunk size c, as (found, result).
  pure def firstAccepted(d: Set[(int, int)], b: Set[int], s: List[int], c: int): (bool, List[int]) =
    starts(s, c).foldl((false, s), (acc, from) =>
      if (acc._1) acc
      else {
        val cand = removeChunk(s, from, c)
        if (validIn(d, cand) and failsIn(b, cand)) (true, cand) else acc
      })

  pure def half(c: int): int = if (c / 2 < 1) 1 else c / 2

  pure def initialChunk(len: int): int = half(len - 1)

  action initWith(d: Set[(int, int)], b: Set[int]): bool = all {
    deps' = d,
    bad' = b,
    kept' = range(0, N),
    chunk' = initialChunk(N),
    done' = (N <= 1),
    rounds' = 0,
    exhausted' = false,
  }

  action init = {
    nondet d = PAIRS.powerset().oneOf()
    nondet b = 0.to(N - 2).powerset().oneOf()
    initWith(d, b)
  }

  // One round: one `quint test` over every removal at the current chunk size
  // (spec 1.3), then the replays of the valid ones in order.
  action round = all {
    not(done),
    val r = firstAccepted(deps, bad, kept, chunk)
    val prefix = r._2.length() - 1
    // Ends by itself: nothing left to remove, or no single removal works.
    val natural = if (r._1) prefix == 0 else chunk == 1
    val budget = rounds + 1 >= MAX_ROUNDS
    all {
      deps' = deps,
      bad' = bad,
      rounds' = rounds + 1,
      done' = (natural or budget),
      exhausted' = (budget and not(natural)),
      kept' = r._2,
      // a chunk wider than the new prefix is narrowed; a failed round halves
      chunk' = if (r._1) (if (chunk > prefix) half(prefix) else chunk) else half(chunk),
    },
  }

  action stutter = all {
    done,
    deps' = deps, bad' = bad, kept' = kept, chunk' = chunk,
    done' = done, rounds' = rounds, exhausted' = exhausted,
  }

  action step = any { round, stutter }

  // 1.3: every accepted candidate is a model trace (Quint accepted it).
  val keptValid = validIn(deps, kept)
  // 1.3: and it still fails with the original failing action.
  val keptFails = failsIn(bad, kept)
  // 1.3: the failing step stays last; the kept steps keep their order.
  val keptOrdered = kept.length() >= 1 and kept[kept.length() - 1] == N - 1 and
    kept.indices().forall(i => i == 0 or kept[i - 1] < kept[i])
  // 1.3: the chunk size stays within 1..N.
  val chunkBounded = chunk >= 1 and chunk <= N
  // 1.3: a loop that ends without exhausting its budget is 1-minimal: no
  // single prefix step can be removed.
  val doneMinimal = (done and not(exhausted)) implies
    0.to(kept.length() - 2).forall(i => {
      val cand = removeChunk(kept, i, 1)
      not(validIn(deps, cand) and failsIn(bad, cand))
    })
  // 1.3 (step 5): the loop ends within its budget of rounds.
  val roundsBounded = rounds <= MAX_ROUNDS

  val invariants = keptValid and keptFails and keptOrdered and chunkBounded and
    doneMinimal and roundsBounded

  // Witnesses (negate with --invariant to get a trace).
  val witShrunk = done and kept.length() < N and not(exhausted)
  val witToFailingStepOnly = done and kept.length() == 1
  val witKeptByDependency = done and toSet(kept).exists(i => not(bad.contains(i)) and i != N - 1)
  val witExhausted = exhausted
}

module shrink6 {
  import shrink(N = 6, MAX_ROUNDS = 50).*
}

module shrink6tight {
  import shrink(N = 6, MAX_ROUNDS = 2).*
}

// 4 steps: 64 x 8 = 512 oracles, about 40 samples each in 20 000 runs.
module shrink4 {
  import shrink(N = 4, MAX_ROUNDS = 50).*
}
