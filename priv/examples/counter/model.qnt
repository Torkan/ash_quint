// The ash_quint example model: two counters with a limit.
//
// Follows the ash_quint model convention: every action sets lastAction
// (init sets Init) and lastResult. Inc over the limit is rejected with
// "over_limit" and changes nothing. Peek is model-only: it changes nothing.
// Regenerate the committed traces with `MIX_ENV=test mix ash_quint.gen counter`.
module counter {
  pure val CTRS = Set("c1", "c2")
  pure val LIMIT = 3

  type Action = Init | Inc({ ctr: str, by: int }) | Reset(str) | Peek(str)
  type Result = Accepted | Rejected(str)

  var counts: str -> int
  var writes: str -> int
  var lastAction: Action
  var lastResult: Result

  pure def valueOf(m: str -> int, k: str): int = if (m.keys().contains(k)) m.get(k) else 0

  action init = all {
    counts' = Map(),
    writes' = Map(),
    lastAction' = Init,
    lastResult' = Accepted,
  }

  action inc(c: str, by: int): bool = {
    val newCount = valueOf(counts, c) + by
    if (newCount > LIMIT) all {
      counts' = counts,
      writes' = writes,
      lastAction' = Inc({ ctr: c, by: by }),
      lastResult' = Rejected("over_limit"),
    } else all {
      counts' = counts.put(c, newCount),
      writes' = writes.put(c, valueOf(writes, c) + 1),
      lastAction' = Inc({ ctr: c, by: by }),
      lastResult' = Accepted,
    }
  }

  action reset(c: str): bool = all {
    valueOf(counts, c) > 0,
    counts' = counts.set(c, 0),
    writes' = writes.put(c, valueOf(writes, c) + 1),
    lastAction' = Reset(c),
    lastResult' = Accepted,
  }

  action peek(c: str): bool = all {
    counts' = counts,
    writes' = writes,
    lastAction' = Peek(c),
    lastResult' = Accepted,
  }

  action step = any {
    nondet c = CTRS.oneOf()
    nondet by = 1.to(2).oneOf()
    inc(c, by),
    nondet c = CTRS.oneOf()
    reset(c),
    nondet c = CTRS.oneOf()
    peek(c),
  }

  val countsWithinLimit = counts.keys().forall(c => counts.get(c) >= 0 and counts.get(c) <= LIMIT)
  val writesNonNegative = writes.keys().forall(c => writes.get(c) >= 0)

  // Witnesses: run with --invariant="not(<name>)" to get a trace reaching them.
  val witOverLimit = lastResult == Rejected("over_limit")
  val witResetAfterInc = match lastAction { Reset(_) => true | _ => false }
}
