// An instance module as random main: counter_app sets CAP, and importing
// counter_app doesn't re-export counter's definitions.
module counter {
  const CAP: int
  var n: int
  action init = n' = 0
  action inc(by: int): bool = all { n + by <= CAP, n' = n + by }
  action step = { nondet by = 1.to(2).oneOf() inc(by) }
}

module counter_app {
  import counter(CAP = 5).*
}
