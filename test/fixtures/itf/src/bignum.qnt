// Decoder fixture: integers that Quint writes as bignumber.js objects.
// Quint 0.33.1 writes any integer with |n| >= 10^15 as {"s", "e", "c"}
// instead of {"#bigint": …}; AshQuint.ITF converts them back.
// Regenerate test/fixtures/itf/bignum.itf.json from the repo root with
//   npx --yes @informalsystems/quint@0.33.1 run test/fixtures/itf/src/bignum.qnt \
//     --main=bignum --seed=1 --max-steps=0 --max-samples=1 \
//     --out-itf=test/fixtures/itf/bignum.itf.json
// then delete "description" and "timestamp" from the top-level "#meta".
module bignum {
  var xs: List[int]
  action init = xs' = [
    999999999999999, 10^15, -10^15, 9007199254740993, -9007199254740993,
    10^18, 123 * 10^16, 10^15 + 1, 10^18 + 1,
    9223372036854775807, -9223372036854775807 - 1
  ]
  action step = xs' = xs
}
