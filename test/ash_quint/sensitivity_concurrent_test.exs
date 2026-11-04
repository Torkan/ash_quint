defmodule AshQuint.SensitivityConcurrentTest do
  use ExUnit.Case, async: true

  import AshQuint.Test.TraceBuilder

  alias AshQuint.{Replay, Sensitivity}
  alias AshQuint.Test.{ConcurrentToyAdapter, ConcurrentToyAdapterBlind, ToyAdapter}

  defmodule BlindDoneAdapter do
    @moduledoc false
    # The concurrent toy adapter whose expected/2 takes an IncDone's count
    # from the system, so dropped starts and completions go unnoticed.
    use AshQuint.Adapter

    alias AshQuint.Step

    @impl true
    defdelegate init(trace, opts), to: ConcurrentToyAdapter

    @impl true
    defdelegate step(ctx, step), to: ConcurrentToyAdapter

    @impl true
    defdelegate project(ctx), to: ConcurrentToyAdapter

    @impl true
    def expected(ctx, %Step{action_taken: "IncDone"}), do: ConcurrentToyAdapter.project(ctx)
    def expected(_ctx, %Step{state: state}), do: Map.take(state, ["count"])

    @impl true
    defdelegate outcome(result), to: ConcurrentToyAdapter

    @impl true
    defdelegate finish(ctx, result), to: ConcurrentToyAdapter
  end

  defp report(states, adapter_opts \\ []) do
    {:ok, report} =
      Replay.run(ConcurrentToyAdapter, trace(states),
        model: :counter,
        adapter_opts: adapter_opts
      )

    report
  end

  defp check(adapter, states_list, adapter_opts \\ []) do
    traces = Enum.map(states_list, &trace/1)
    Sensitivity.check(adapter, traces, model: :counter, adapter_opts: adapter_opts)
  end

  # o1 is rejected, so only o2's completion changes the state.
  defp rejected_then_accepted do
    [
      init(),
      inc_start(0, "o1", 5),
      inc_done(0, "o1", {:rejected, "too_big"}),
      inc_start(0, "o2", 2),
      inc_done(2, "o2")
    ]
  end

  describe "overlaps/1" do
    test "an op overlaps when another op is in flight at any point between its start and completion" do
      # o1 and o2 overlap; o3 starts after both completed; o4 starts while
      # o3 is in flight and outlives it; o5 starts after o3 and o4 are done
      # and never completes.
      states = [
        init(),
        inc_start(0, "o1", 1),
        inc_start(0, "o2", 1),
        inc_done(1, "o1"),
        inc_done(2, "o2"),
        inc_start(2, "o3", 5),
        inc_start(2, "o4", 1),
        inc_done(2, "o3", {:rejected, "too_big"}),
        inc_done(3, "o4"),
        inc_start(3, "o5", 5)
      ]

      assert Sensitivity.overlaps(report(states)) == %{
               1 => true,
               2 => true,
               5 => true,
               6 => true,
               9 => false
             }
    end

    test "an op id reused after its completion is a new op" do
      states = [
        init(),
        inc_start(0, "o1", 1),
        inc_done(1, "o1"),
        inc_start(1, "o1", 1),
        inc_start(1, "o2", 1),
        inc_done(2, "o2"),
        inc_done(3, "o1")
      ]

      assert Sensitivity.overlaps(report(states)) == %{1 => false, 3 => true, 4 => true}
    end

    test "a sequential report has no starts" do
      assert Sensitivity.overlaps(report([init(), inc(1, 1)])) == %{}
    end
  end

  describe "dropped calls" do
    test "IncDone is dropped at its first state-changing completion" do
      assert %{survived: survived} = check(BlindDoneAdapter, [rejected_then_accepted()])
      assert {:drop, "random t", 4, "IncDone"} in survived

      assert %{survived: [], tested: tested} =
               check(ConcurrentToyAdapter, [rejected_then_accepted()])

      assert {:call, "IncDone"} in tested
    end

    test "IncStart is dropped at the start whose completion changes the state and is tested, not reported unchanged" do
      assert %{survived: survived} = check(BlindDoneAdapter, [rejected_then_accepted()])
      assert {:drop, "random t", 3, "IncStart"} in survived

      assert %{survived: [], untested: untested, tested: tested} =
               check(ConcurrentToyAdapter, [rejected_then_accepted()])

      assert {:call, "IncStart"} in tested
      refute {:call, "IncStart"} in untested
    end

    test "a start whose ops never change state is untested {:call, \"IncStart\"}" do
      states = [init(), inc_start(0, "o1", 5), inc_done(0, "o1", {:rejected, "too_big"})]
      assert %{survived: [], untested: untested} = check(ConcurrentToyAdapter, [states])
      assert {:call, "IncStart"} in untested
      assert {:call, "IncDone"} in untested
    end

    test "advances are never dropped" do
      states = [init(), inc_start(0, "o1", 1), inc_advance(0, "o1"), inc_done(1, "o1")]

      assert %{survived: [], untested: untested, tested: tested} =
               check(ConcurrentToyAdapter, [states], faults: [:two_gates])

      refute Enum.any?(untested ++ tested, &match?({:call, "IncRead"}, &1))
    end
  end

  describe "serialization mutant" do
    # o1 and o2 overlap, and o1 completes first, so running o1 to completion
    # at its start changes nothing but the count at steps 1 and 2.
    defp first_completes_first do
      [init(), inc_start(0, "o1", 1), inc_start(0, "o2", 1), inc_done(1, "o1"), inc_done(2, "o2")]
    end

    # o1 is rejected however it runs, so serializing it is invisible.
    defp rejected_overlap do
      [
        init(),
        inc_start(0, "o1", 5),
        inc_start(0, "o2", 1),
        inc_done(0, "o1", {:rejected, "too_big"}),
        inc_done(1, "o2")
      ]
    end

    defp race do
      [
        init(),
        inc_start(0, "o1", 2),
        inc_start(0, "o2", 2),
        inc_done(2, "o2"),
        inc_done(2, "o1", {:rejected, "too_big"})
      ]
    end

    test "an overlapping start whose serialization fails the replay is tested" do
      assert %{survived: [], untested: [], tested: tested, never_overlap: []} =
               check(ConcurrentToyAdapter, [first_completes_first()])

      assert {:interleaving, "IncStart"} in tested
    end

    test "toy adapter whose projection is blind until completion (ConcurrentToyAdapterBlind) reports serializing IncStart is never detected" do
      result = check(ConcurrentToyAdapterBlind, [first_completes_first()])
      assert %{survived: [], untested: [{:interleaving, "IncStart"}], never_overlap: []} = result
      refute {:interleaving, "IncStart"} in result.tested
      assert Sensitivity.format(result) == "serializing IncStart is never detected"
    end

    test "sequential models get no interleaving targets" do
      states = [init(), inc(1, 1), inc(3, 2), reset()]

      assert %{survived: [], untested: [], tested: tested, never_overlap: []} =
               check(ToyAdapter, [states])

      refute Enum.any?(tested, &match?({:interleaving, _action}, &1))
    end

    test "tries the next overlapping trace when the first doesn't detect" do
      assert %{untested: [{:interleaving, "IncStart"}]} =
               check(ConcurrentToyAdapter, [rejected_overlap()])

      assert %{survived: [], untested: [], tested: tested} =
               check(ConcurrentToyAdapter, [rejected_overlap(), race()])

      assert {:interleaving, "IncStart"} in tested
    end

    test "an action whose ops never overlap is untested, with its own line" do
      states = [init(), inc_start(0, "o1", 1), inc_done(1, "o1")]
      result = check(ConcurrentToyAdapter, [states])

      assert %{survived: [], untested: [{:interleaving, "IncStart"}], never_overlap: ["IncStart"]} =
               result

      assert Sensitivity.format(result) == "IncStart never overlaps another op in any trace"
    end
  end
end
