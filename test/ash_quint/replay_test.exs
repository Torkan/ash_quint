defmodule AshQuint.ReplayTest do
  use ExUnit.Case, async: true

  import AshQuint.Test.TraceBuilder

  alias AshQuint.{ITF, Replay}
  alias AshQuint.Test.{ToyAdapter, ToyAdapterMissingKey, ToyAdapterNoReset}

  @prefix "counter random t, step"
  @interleaved "interleaved trace: concurrent replay is out of scope for ash_quint v1"

  defmodule SkipAll do
    @moduledoc false
    use AshQuint.Adapter

    @impl true
    def init(_trace, _opts), do: {:ok, %{}}

    @impl true
    def step(ctx, _step), do: {:skip, ctx}

    @impl true
    def project(_ctx), do: %{}
  end

  defmodule ErrorReturn do
    @moduledoc false
    use AshQuint.Adapter

    @impl true
    def init(_trace, _opts), do: {:ok, %{}}

    @impl true
    def step(_ctx, _step), do: {:error, :boom}

    @impl true
    def project(_ctx), do: %{}
  end

  defmodule NoUse do
    @moduledoc false
    # An adapter that implements the behaviour without `use AshQuint.Adapter`,
    # so it has no outcome/1.
    @behaviour AshQuint.Adapter

    @impl true
    defdelegate init(trace, opts), to: ToyAdapter

    @impl true
    def step(ctx, %AshQuint.Step{action_taken: "Peek"}), do: {:ok, :boom, ctx}
    def step(ctx, step), do: ToyAdapter.step(ctx, step)

    @impl true
    defdelegate project(ctx), to: ToyAdapter
  end

  defmodule ExtraExpected do
    @moduledoc false
    # The toy adapter whose expected/2 also returns the unprojected "ticks".
    use AshQuint.Adapter

    @impl true
    defdelegate init(trace, opts), to: ToyAdapter

    @impl true
    defdelegate step(ctx, step), to: ToyAdapter

    @impl true
    defdelegate project(ctx), to: ToyAdapter

    @impl true
    def expected(_ctx, step), do: %{"count" => step.state["count"], "ticks" => step.index}

    @impl true
    defdelegate outcome(result), to: ToyAdapter
  end

  defmodule RaisingProject do
    @moduledoc false
    # The toy adapter whose project/1 (`:project` in opts) or expected/2
    # (`:expected`) raises.
    use AshQuint.Adapter

    @impl true
    def init(trace, opts) do
      {:ok, ctx} = ToyAdapter.init(trace, opts)
      {:ok, Map.put(ctx, :raise, Keyword.fetch!(opts, :raise))}
    end

    @impl true
    defdelegate step(ctx, step), to: ToyAdapter

    @impl true
    def project(%{raise: :project}), do: raise("no connection")
    def project(ctx), do: ToyAdapter.project(ctx)

    @impl true
    def expected(%{raise: :expected}, _step), do: raise(ArgumentError, "bad model value")
    def expected(_ctx, step), do: Map.take(step.state, ["count"])

    @impl true
    defdelegate outcome(result), to: ToyAdapter
  end

  defp run(states, faults \\ [], opts \\ []) do
    {trace_opts, opts} = Keyword.split(opts, [:results])
    adapter = Keyword.get(opts, :adapter, ToyAdapter)
    opts = Keyword.delete(opts, :adapter)

    Replay.run(
      adapter,
      trace(states, trace_opts),
      [model: :counter, adapter_opts: [faults: faults]] ++ opts
    )
  end

  defp message(states, faults \\ [], opts \\ []) do
    assert {:error, %{message: message}} = run(states, faults, opts)
    message
  end

  defp clean, do: [init(), inc(1, 1), inc(3, 2), inc(3, 1, {:rejected, "too_big"}), reset()]

  test "passes a trace the system follows" do
    assert {:ok, report} = run(clean())

    assert [
             %{index: 1, action: "Inc", kind: :ok, expected: %{"count" => 1}},
             %{index: 2, action: "Inc", kind: :ok, expected: %{"count" => 3}},
             %{index: 3, action: "Inc", kind: :ok, expected: %{"count" => 3}},
             %{index: 4, action: "Reset", kind: :ok, expected: %{"count" => 0}}
           ] = report.synced

    assert report.initial_expected == %{"count" => 0}
  end

  test "outcome mismatch" do
    assert message(clean(), [:wrong_code]) ==
             ~s(counter random t, step 3 \(Inc\), seed 7: outcome: expected {:rejected, "too_big"}, got {:rejected, "other"})
  end

  test "failed system call" do
    assert {:error, failure} = run(clean(), [:crash])
    assert failure.index == 1
    assert failure.action == "Inc"

    assert failure.message ==
             "#{@prefix} 1 (Inc), seed 7: system call failed: db down\n" <>
               "key \"count\":\n  expected: 1\n  actual:   0"
  end

  test "failed call fails even without an expected result" do
    assert message(clean(), [:crash], results: false) ==
             "#{@prefix} 1 (Inc), seed 7: system call failed: db down\n" <>
               "key \"count\":\n  expected: 1\n  actual:   0"
  end

  test "absent result skips the outcome assertion" do
    assert {:ok, _report} = run(clean(), [:wrong_code], results: false)
  end

  test "state mismatch shows a per-key diff" do
    assert message(clean(), [:off_by_one]) ==
             "#{@prefix} 1 (Inc), seed 7: key \"count\":\n  expected: 1\n  actual:   2"
  end

  test "the diff pretty-prints large values" do
    big = Map.new(1..12, &{"key_#{&1}", &1})
    states = [init(), Map.put(inc(1, 1), "count", big)]

    assert message(states) ==
             "#{@prefix} 1 (Inc), seed 7: key \"count\":\n  expected: " <>
               inspect(big, pretty: true) <> "\n  actual:   1"
  end

  test "missing expected key" do
    assert message(clean(), [], adapter: ToyAdapterMissingKey) ==
             "#{@prefix} 1 (Inc), seed 7: expected/2 returned no value for key \"count\""
  end

  test "extra projected key not in the model" do
    assert message(clean(), [:extra_key]) ==
             "#{@prefix} 1 (Inc), seed 7: expected/2 returned no value for key \"ghost\""
  end

  test "failed invariants are all reported with the diff" do
    assert message([init(), inc(1, 1), reset()], [:negative]) ==
             "#{@prefix} 2 (Reset), seed 7: key \"count\":\n  expected: 0\n  actual:   -1\n" <>
               "invariant non_negative: count is -1"
  end

  test "a raising invariant is reported" do
    assert message([init(), inc(1, 1)], [:invariant_raises]) ==
             "#{@prefix} 1 (Inc), seed 7: invariant non_negative raised: invariant blew up"
  end

  test "pending then ok" do
    assert {:ok, report} = run([init(), begin(0, 2), commit(2)])
    assert [%{index: 2, action: "Commit", kind: :ok}] = report.synced
  end

  test "second pending is refused" do
    assert message([init(), begin(0, 1), begin(0, 2)]) ==
             "#{@prefix} 2 (Begin), seed 7: #{@interleaved}"
  end

  test "skip while pending is refused" do
    assert message([init(), begin(0, 1), peek(0)]) ==
             "#{@prefix} 2 (Peek), seed 7: #{@interleaved}"
  end

  test "trace ending pending is refused" do
    assert message([init(), begin(0, 1)]) == "#{@prefix} 1 (Begin), seed 7: #{@interleaved}"
  end

  test "skip compares state without an outcome" do
    assert {:ok, report} = run([init(), peek(0, {:rejected, "x"})])
    assert [%{index: 1, action: "Peek", kind: :skip}] = report.synced

    assert message([init(), peek(1)]) ==
             "#{@prefix} 1 (Peek), seed 7: key \"count\":\n  expected: 1\n  actual:   0"
  end

  test "missing step clause" do
    assert message(clean(), [], adapter: ToyAdapterNoReset) ==
             "#{@prefix} 4 (Reset), seed 7: adapter AshQuint.Test.ToyAdapterNoReset " <>
               "has no step/2 clause for `Reset`"
  end

  test "other exceptions in step/2 propagate" do
    # Commit without a Begin has no ToyAdapter clause, but the clause is
    # missing in ToyAdapter, not in the adapter being replayed.
    assert_raise FunctionClauseError, fn ->
      run([init(), commit(1)], [], adapter: ToyAdapterNoReset)
    end
  end

  test "bad return value" do
    assert message(clean(), [:bad_return]) ==
             "#{@prefix} 1 (Inc), seed 7: step/2 returned :ok; " <>
               "expected {:ok, result, ctx}, {:pending, ctx} or {:skip, ctx}"
  end

  test "an {:error, _} return value is a bad return value" do
    assert message(clean(), [], adapter: ErrorReturn) ==
             "#{@prefix} 1 (Inc), seed 7: step/2 returned {:error, :boom}; " <>
               "expected {:ok, result, ctx}, {:pending, ctx} or {:skip, ctx}"
  end

  test "wrong initial action" do
    states = [inc(1, 1), inc(2, 1)]

    assert message(states) ==
             "#{@prefix} 0 (Inc), seed 7: initial state's action is Inc, expected Init"

    assert {:ok, _report} = run([inc(0, 1), inc(1, 1)], [], init_action: "Inc")
  end

  test "missing lastAction" do
    assert message([init(), Map.delete(inc(1, 1), "lastAction")]) ==
             "#{@prefix} 1 (?), seed 7: no action at lastAction"
  end

  test "an invalid initial state is reported at step 0" do
    assert message([Map.delete(init(), "lastAction"), inc(1, 1)]) ==
             "#{@prefix} 0 (?), seed 7: no action at lastAction"
  end

  test "custom action and result paths" do
    nest = fn state ->
      state
      |> Map.drop(["lastAction", "lastResult"])
      |> Map.put("last", %{"action" => state["lastAction"], "result" => state["lastResult"]})
    end

    states = Enum.map(clean(), nest)

    assert {:ok, _report} =
             run(states, [], action_path: ["last", "action"], result_path: ["last", "result"])

    assert message(states, [:wrong_code],
             action_path: ["last", "action"],
             result_path: ["last", "result"]
           ) =~ "step 3 (Inc), seed 7: outcome: expected"
  end

  test "an exception in project/1 on the initial state fails at step 0" do
    assert {:error, %{index: 0, action: "Init", message: message}} =
             Replay.run(RaisingProject, trace(clean()),
               model: :counter,
               adapter_opts: [raise: :project]
             )

    assert message == "#{@prefix} 0 (Init), seed 7: project/1 raised: no connection"
  end

  test "an exception in expected/2 on the initial state fails at step 0" do
    assert {:error, %{index: 0, action: "Init", message: message}} =
             Replay.run(RaisingProject, trace(clean()),
               model: :counter,
               adapter_opts: [raise: :expected]
             )

    assert message == "#{@prefix} 0 (Init), seed 7: expected/2 raised: bad model value"
  end

  test "an adapter without use AshQuint.Adapter gets the default outcome/1" do
    assert {:ok, %{synced: [_, _]}} = run([init(), inc(1, 1), reset()], [], adapter: NoUse)

    assert message([init(), peek(0)], [], adapter: NoUse) ==
             "#{@prefix} 1 (Peek), seed 7: system call failed: :boom"
  end

  test "the report keeps only the projected keys of expected/2" do
    assert {:ok, report} = run([init(), inc(1, 1)], [], adapter: ExtraExpected)

    assert report.initial_expected == %{"count" => 0}
    assert [%{index: 1, expected: %{"count" => 1} = expected}] = report.synced
    assert Map.keys(expected) == ["count"]
  end

  test "run! raises ExUnit.AssertionError" do
    error =
      assert_raise ExUnit.AssertionError, fn ->
        Replay.run!(ToyAdapter, trace(clean()),
          model: :counter,
          adapter_opts: [faults: [:off_by_one]]
        )
      end

    assert error.message ==
             "#{@prefix} 1 (Inc), seed 7: key \"count\":\n  expected: 1\n  actual:   2"
  end

  test "run! returns the report" do
    assert %{synced: [_, _, _, _]} = Replay.run!(ToyAdapter, trace(clean()), model: :counter)
  end

  test "perturb mutation fails at that step on that key" do
    assert {:error, %{index: 1, message: message}} =
             run(clean(), [], mutate: {:perturb, 1, "count"})

    assert message ==
             "#{@prefix} 1 (Inc), seed 7: key \"count\":\n" <>
               "  expected: {:ash_quint_mutated, \"count\"}\n  actual:   1"
  end

  test "drop mutation skips the system call" do
    assert {:error, %{index: 1, message: message}} = run(clean(), [], mutate: {:drop, 1})
    assert message == "#{@prefix} 1 (Inc), seed 7: key \"count\":\n  expected: 1\n  actual:   0"
  end

  test "a dropped call closes the pending step it would have completed" do
    assert {:error, %{index: 2, message: message}} =
             run([init(), begin(0, 2), commit(2)], [], mutate: {:drop, 2})

    assert message ==
             "#{@prefix} 2 (Commit), seed 7: key \"count\":\n  expected: 2\n  actual:   0"
  end

  test "a dropped call reports the step as skipped" do
    states = [init(), inc(0, 3, {:rejected, "x"}), inc(3, 3)]

    assert {:ok, %{synced: [%{index: 1, kind: :skip}, %{index: 2, kind: :ok}]}} =
             run(states, [], mutate: {:drop, 1})
  end

  test "replays the real decoder fixture" do
    trace = ITF.read!("test/fixtures/itf/run.itf.json")
    assert {:ok, report} = Replay.run(SkipAll, trace, model: :fixture)
    assert length(report.synced) == length(trace.states) - 1
  end
end
