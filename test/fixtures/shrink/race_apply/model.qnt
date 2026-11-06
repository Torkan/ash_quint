// A copy of priv/examples/race/model.qnt with an `apply` action, for the
// shrink tests' `shrink: [apply: "apply"]` round 0 (AshQuint.ShrinkTest).
// The ash_quint concurrency example: two Incs that may overlap, against a
// limit.
//
// Follows the ash_quint model convention for concurrency: IncStart starts a
// call that stays in flight (lastResult Pending), and IncDone completes it,
// with the call's outcome. Both carry the operation id in `op`. inflight is
// bookkeeping the adapter doesn't project. The model is the correct system:
// an Inc takes effect atomically when it completes.
// Regenerate the committed traces with `MIX_ENV=test mix ash_quint.gen race`.
module race {
  pure val OPS = Set("o1", "o2")
  pure val LIMIT = 3

  type Action = Init | IncStart({ op: str, by: int }) | IncDone({ op: str })
  type Result = Accepted | Rejected(str) | Pending

  var count: int
  var writes: int
  var inflight: str -> int          // op -> by; not projected
  var finished: Set[str]
  var lastAction: Action
  var lastResult: Result

  action init = all {
    count' = 0, writes' = 0, inflight' = Map(), finished' = Set(),
    lastAction' = Init, lastResult' = Accepted,
  }

  action incStart(o: str, by: int): bool = all {
    not(inflight.keys().contains(o)), not(finished.contains(o)),
    inflight' = inflight.put(o, by),
    count' = count, writes' = writes, finished' = finished,
    lastAction' = IncStart({ op: o, by: by }),
    lastResult' = Pending,
  }

  action applyInc(o: str, by: int): bool = all {
    inflight' = inflight.keys().exclude(Set(o)).mapBy(k => inflight.get(k)),
    finished' = finished.union(Set(o)),
    lastAction' = IncDone({ op: o }),
    if (count + by > LIMIT) all {
      count' = count, writes' = writes, lastResult' = Rejected("over_limit"),
    } else all {
      count' = count + by, writes' = writes + 1, lastResult' = Accepted,
    },
  }

  action incDone(o: str): bool = all {
    inflight.keys().contains(o),
    applyInc(o, inflight.get(o)),
  }

  action step = any {
    nondet o = OPS.oneOf()
    nondet by = 1.to(2).oneOf()
    incStart(o, by),
    nondet o = OPS.oneOf()
    incDone(o),
  }

  // Takes a step's action value: what shrinking calls with apply: "apply".
  action apply(a: Action): bool = match a {
    | Init => init
    | IncStart(r) => incStart(r.op, r.by)
    | IncDone(r) => incDone(r.op)
  }

  val countWithinLimit = count >= 0 and count <= LIMIT

  // Witness: both requests in flight at once.
  val witOverlap = inflight.keys().size() == 2
}
