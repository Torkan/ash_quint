defmodule AshQuint.CounterExampleTest do
  # The counter example end to end: every committed trace of
  # priv/examples/counter replays against the Ash resource.
  use ExUnit.Case, async: true

  use AshQuint.Case,
    model: :counter,
    adapter: AshQuint.Test.CounterAdapter,
    sensitivity: true

  alias AshQuint.{Manifest, Replay, Step, Trace}
  alias AshQuint.Test.CounterAdapter

  defmodule OffByOneAdapter do
    @moduledoc false
    # The counter adapter whose Inc adds one more than asked.
    use AshQuint.Adapter

    alias AshQuint.Test.CounterAdapter

    @impl true
    defdelegate init(trace, opts), to: CounterAdapter

    @impl true
    def step(ctx, %Step{action_taken: "Inc", nondet_picks: %{"by" => by} = picks} = step),
      do: CounterAdapter.step(ctx, %{step | nondet_picks: %{picks | "by" => by + 1}})

    def step(ctx, step), do: CounterAdapter.step(ctx, step)

    @impl true
    defdelegate project(ctx), to: CounterAdapter

    @impl true
    defdelegate outcome(result), to: CounterAdapter
  end

  @out "priv/examples/counter/traces"

  test "a broken adapter fails with the trace, step, action and seed" do
    %Manifest{seed: seed} = Manifest.read!(Path.join(@out, "manifest.json"))

    trace =
      Trace.load!(Path.join(@out, "scenario_incTest.itf.json"),
        name: "incTest",
        source: :scenario,
        seed: seed
      )

    assert {:error, failure} = Replay.run(OffByOneAdapter, trace, model: :counter)

    assert failure.message ==
             """
             counter scenario incTest, step 1 (Inc), seed 20261102: key "counts":
               expected: %{"c1" => 2}
               actual:   %{"c1" => 3}\
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
