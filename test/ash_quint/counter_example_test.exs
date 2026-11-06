defmodule AshQuint.CounterExampleTest do
  # The counter example end to end: every committed trace of
  # priv/examples/counter replays against the Ash resource, and
  # `mix ash_quint.explore counter` replays fresh ones (explore: true).
  use ExUnit.Case, async: true

  use AshQuint.Case,
    model: :counter,
    adapter: AshQuint.Test.CounterAdapter,
    sensitivity: true,
    explore: true

  alias AshQuint.{Manifest, Replay, Trace}
  alias AshQuint.Test.{CounterAdapter, CounterAdapterOffByOne}

  @out "priv/examples/counter/traces"

  test "a broken adapter fails with the trace, step, action and seed" do
    %Manifest{seed: seed} = Manifest.read!(Path.join(@out, "manifest.json"))

    trace =
      Trace.load!(Path.join(@out, "scenario_incTest.itf.json"),
        name: "incTest",
        source: :scenario,
        seed: seed
      )

    assert {:error, failure} = Replay.run(CounterAdapterOffByOne, trace, model: :counter)

    assert failure.message ==
             """
             counter scenario incTest, step 1 (Inc), seed 20261102: key "counts":
               expected: %{"c1" => 2}
               actual:   %{"c1" => 3}
             model step: Inc %{"by" => 2, "ctr" => "c1"}, result :accepted\
             """
  end

  test "the invariants mirror the model's" do
    [counts_within_limit: counts, writes_non_negative: writes] = CounterAdapter.invariants()
    ok = %{"counts" => %{"c1" => 3, "c2" => 0}, "writes" => %{"c1" => 0}}

    assert counts.(ok, %{}) == :ok
    assert writes.(ok, %{}) == :ok

    assert counts.(%{ok | "counts" => %{"c1" => 4, "c2" => -1}}, %{}) ==
             {:error, ~s(outside 0..3: %{"c1" => 4, "c2" => -1})}

    assert writes.(%{ok | "writes" => %{"c2" => -1}}, %{}) ==
             {:error, ~s(negative: %{"c2" => -1})}
  end
end
