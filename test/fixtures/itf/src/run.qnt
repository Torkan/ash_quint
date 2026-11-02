// Decoder fixture: every ITF value form and every variant shape.
// Regenerate test/fixtures/itf/run.itf.json from the repo root with
//   npx --yes @informalsystems/quint@0.33.1 run test/fixtures/itf/src/run.qnt \
//     --main=fixture --seed=1 --max-steps=4 --max-samples=1 \
//     --out-itf=test/fixtures/itf/run.itf.json
// then delete "description" and "timestamp" from the top-level "#meta".
//
// n starts at 2^40, below 10^15, so it's written as #bigint; larger values
// are covered by bignum.qnt.
module fixture {
  type Action = Init | Inc({ by: int }) | SetTo(int) | Reset
  type Result = Accepted | Rejected(str)

  var n: int
  var s: str
  var m: str -> int
  var st: Set[int]
  var tup: (int, str)
  var lst: List[int]
  var rec: { a: int, b: str }
  var lastAction: Action
  var lastResult: Result

  action init = all {
    n' = 1099511627776,
    s' = "hello",
    m' = Map("x" -> 1, "y" -> 2),
    st' = Set(1, 2, 3),
    tup' = (1, "one"),
    lst' = [1, 2],
    rec' = { a: 1, b: "b" },
    lastAction' = Init,
    lastResult' = Accepted,
  }

  action unchangedRest = all {
    s' = s,
    m' = m,
    st' = st,
    tup' = tup,
    lst' = lst,
    rec' = rec,
  }

  action inc = all {
    n' = n + 1,
    lastAction' = Inc({ by: 1 }),
    lastResult' = Accepted,
    unchangedRest,
  }

  action setTo = all {
    n' = 5,
    lastAction' = SetTo(5),
    lastResult' = Accepted,
    unchangedRest,
  }

  action reset = all {
    n' = n,
    lastAction' = Reset,
    lastResult' = Rejected("not_allowed"),
    unchangedRest,
  }

  action step = any { inc, setTo, reset }
}
