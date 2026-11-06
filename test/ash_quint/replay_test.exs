defmodule AshQuint.ReplayTest do
  use ExUnit.Case, async: true

  import AshQuint.Test.TraceBuilder

  alias AshQuint.{ITF, Replay}
  alias AshQuint.Test.{ToyAdapter, ToyAdapterCounts, ToyAdapterMissingKey, ToyAdapterNoReset}

  @prefix "counter random t, step"
  @use_start "use {:start, op, call, ctx} and {:complete, op, ctx} for calls that stay in flight"

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

  defmodule ShortMapAdapter do
    @moduledoc false
    # The toy adapter projecting its count as the short map %{"c1" => count}.
    use AshQuint.Adapter

    alias AshQuint.Step

    @impl true
    defdelegate init(trace, opts), to: ToyAdapter

    @impl true
    defdelegate step(ctx, step), to: ToyAdapter

    @impl true
    def project(ctx), do: %{"count" => %{"c1" => ctx.count}}

    @impl true
    def expected(_ctx, %Step{state: state}), do: %{"count" => %{"c1" => state["count"]}}

    @impl true
    defdelegate outcome(result), to: ToyAdapter
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

  defmodule Finishing do
    @moduledoc false
    # The toy adapter with a finish/2 that sends {:finished, ctx, result} to
    # the test and returns opts[:finish] (default :ok; :raise raises).
    # ctx.steps counts step/2 calls. opts[:raise]: {:step, n} raises in the
    # n-th step/2 call, {:project, n} in project/1 after n calls, and
    # {:throw, n} throws from the n-th step/2 call.
    use AshQuint.Adapter

    @impl true
    def init(trace, opts) do
      {:ok, ctx} = ToyAdapter.init(trace, opts)

      {:ok,
       Map.merge(ctx, %{
         test: Keyword.fetch!(opts, :test),
         finish: Keyword.get(opts, :finish, :ok),
         raise: Keyword.get(opts, :raise),
         steps: 0
       })}
    end

    @impl true
    def step(ctx, step) do
      ctx = %{ctx | steps: ctx.steps + 1}

      case ctx.raise do
        {:step, n} when n == ctx.steps -> raise "step blew up"
        {:throw, n} when n == ctx.steps -> throw(:thrown)
        _other -> ToyAdapter.step(ctx, step)
      end
    end

    @impl true
    def project(%{raise: {:project, n}, steps: n}), do: raise("no connection")
    def project(ctx), do: ToyAdapter.project(ctx)

    @impl true
    defdelegate outcome(result), to: ToyAdapter

    @impl true
    defdelegate invariants, to: ToyAdapter

    @impl true
    def finish(ctx, result) do
      send(ctx.test, {:finished, ctx, result})
      if ctx.finish == :raise, do: raise("cleanup failed"), else: ctx.finish
    end
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

  test "synced entries carry op: nil for sequential steps" do
    assert {:ok, report} = run(clean())
    assert Enum.all?(report.synced, &(&1.op == nil))
  end

  test "outcome mismatch" do
    assert message(clean(), [:wrong_code]) ==
             ~s(counter random t, step 3 \(Inc\), seed 7: outcome: expected {:rejected, "too_big"}, got {:rejected, "other"}) <>
               ~s(\nmodel step: Inc %{"by" => 1}, result {:rejected, "too_big"})
  end

  test "failed system call" do
    assert {:error, failure} = run(clean(), [:crash])
    assert failure.index == 1
    assert failure.action == "Inc"

    assert failure.message ==
             "#{@prefix} 1 (Inc), seed 7: system call failed: db down\n" <>
               "key \"count\":\n  expected: 1\n  actual:   0" <>
               ~s(\nmodel step: Inc %{"by" => 1}, result :accepted)
  end

  test "failed call fails even without an expected result" do
    assert message(clean(), [:crash], results: false) ==
             "#{@prefix} 1 (Inc), seed 7: system call failed: db down\n" <>
               "key \"count\":\n  expected: 1\n  actual:   0" <>
               ~s(\nmodel step: Inc %{"by" => 1})
  end

  test "absent result skips the outcome assertion" do
    assert {:ok, _report} = run(clean(), [:wrong_code], results: false)
  end

  test "state mismatch shows a per-key diff" do
    assert message(clean(), [:off_by_one]) ==
             "#{@prefix} 1 (Inc), seed 7: key \"count\":\n  expected: 1\n  actual:   2" <>
               ~s(\nmodel step: Inc %{"by" => 1}, result :accepted)
  end

  test "the diff pretty-prints large values" do
    big = Map.new(1..12, &{"key_#{&1}", &1})
    states = [init(), Map.put(inc(1, 1), "count", big)]

    assert message(states) ==
             "#{@prefix} 1 (Inc), seed 7: key \"count\":\n  expected: " <>
               inspect(big, pretty: true) <>
               ~s(\n  actual:   1\nmodel step: Inc %{"by" => 1}, result :accepted)
  end

  test "a short map mismatch keeps the expected/actual form" do
    assert message(clean(), [:off_by_one], adapter: ShortMapAdapter) ==
             "#{@prefix} 1 (Inc), seed 7: key \"count\":\n" <>
               ~s(  expected: %{"c1" => 1}\n  actual:   %{"c1" => 2}) <>
               ~s(\nmodel step: Inc %{"by" => 1}, result :accepted)
  end

  test "a long map mismatch lists only the differing entries" do
    states = Enum.map(clean(), &ToyAdapterCounts.with_counts/1)

    assert message(states, [:off_by_one], adapter: ToyAdapterCounts) ==
             "#{@prefix} 1 (Inc), seed 7: " <>
               ~s(key "counts":\n  "c07": expected 1, actual 2) <>
               ~s(\nmodel step: Inc %{"by" => 1}, result :accepted)
  end

  test "a long non-map mismatch keeps the whole values" do
    long = String.duplicate("x", 70)
    states = [init(), Map.put(inc(1, 1), "count", long)]

    assert message(states) ==
             "#{@prefix} 1 (Inc), seed 7: key \"count\":\n" <>
               "  expected: #{inspect(long)}\n  actual:   1" <>
               ~s(\nmodel step: Inc %{"by" => 1}, result :accepted)
  end

  test "missing expected key" do
    assert message(clean(), [], adapter: ToyAdapterMissingKey) ==
             "#{@prefix} 1 (Inc), seed 7: expected/2 returned no value for key \"count\"" <>
               ~s(\nmodel step: Inc %{"by" => 1}, result :accepted)
  end

  test "extra projected key not in the model" do
    assert message(clean(), [:extra_key]) ==
             "#{@prefix} 1 (Inc), seed 7: expected/2 returned no value for key \"ghost\"" <>
               ~s(\nmodel step: Inc %{"by" => 1}, result :accepted)
  end

  test "failed invariants are all reported with the diff" do
    assert message([init(), inc(1, 1), reset()], [:negative]) ==
             "#{@prefix} 2 (Reset), seed 7: key \"count\":\n  expected: 0\n  actual:   -1\n" <>
               "invariant non_negative: count is -1" <> ~s(\nmodel step: Reset, result :accepted)
  end

  test "a raising invariant is reported" do
    assert message([init(), inc(1, 1)], [:invariant_raises]) ==
             "#{@prefix} 1 (Inc), seed 7: invariant non_negative raised: invariant blew up" <>
               ~s(\nmodel step: Inc %{"by" => 1}, result :accepted)
  end

  test "pending then ok" do
    assert {:ok, report} = run([init(), begin(0, 2), commit(2)])
    assert [%{index: 2, action: "Commit", kind: :ok}] = report.synced
  end

  test "second pending is refused" do
    assert message([init(), begin(0, 1), begin(0, 2)]) ==
             "#{@prefix} 2 (Begin), seed 7: interleaved trace: two {:pending, …} steps " <>
               "overlap; #{@use_start}" <>
               ~s(\nmodel step: Begin %{"value" => 2}, result :accepted)
  end

  test "skip while pending is refused" do
    assert message([init(), begin(0, 1), peek(0)]) ==
             "#{@prefix} 2 (Peek), seed 7: interleaved trace: {:skip, …} while a " <>
               "{:pending, …} step is open; #{@use_start}" <>
               ~s(\nmodel step: Peek, result :accepted)
  end

  test "trace ending pending is refused" do
    assert message([init(), begin(0, 1)]) ==
             "#{@prefix} 1 (Begin), seed 7: interleaved trace: the trace ends with this " <>
               "{:pending, …} step open; #{@use_start}" <>
               ~s(\nmodel step: Begin %{"value" => 1}, result :accepted)
  end

  describe "a step the model keeps in flight (Pending)" do
    defp in_flight(tag, result \\ {:variant, "Pending", {}}) do
      %{
        "count" => 0,
        "lastAction" => {:variant, tag, %{"by" => 1, "op" => "o1"}},
        "lastResult" => result
      }
    end

    test "refuses {:ok, …}" do
      assert message([init(), in_flight("Inc")]) ==
               "#{@prefix} 1 (Inc), seed 7: the model keeps Inc in flight (lastResult Pending), " <>
                 "but step/2 returned {:ok, …}" <>
                 ~s(\nmodel step: Inc %{"by" => 1, "op" => "o1"}, result :pending)
    end

    test "refuses {:skip, …}" do
      assert message([init(), in_flight("Peek")]) =~
               "#{@prefix} 1 (Peek), seed 7: the model keeps Peek in flight (lastResult Pending), " <>
                 "but step/2 returned {:skip, …}"
    end

    test "uses the pending_result option" do
      states = [init(), in_flight("Inc", {:variant, "InFlight", {}})]

      assert {:error, failure} =
               Replay.run(ToyAdapter, trace(states), model: :counter, pending_result: "InFlight")

      assert failure.message =~ "the model keeps Inc in flight (lastResult InFlight)"

      assert {:error, failure} = Replay.run(ToyAdapter, trace(states), model: :counter)
      assert failure.message =~ "result at lastResult must be Accepted, Rejected(str) or Pending"
    end
  end

  test "skip compares state without an outcome" do
    assert {:ok, report} = run([init(), peek(0, {:rejected, "x"})])
    assert [%{index: 1, action: "Peek", kind: :skip}] = report.synced

    assert message([init(), peek(1)]) ==
             "#{@prefix} 1 (Peek), seed 7: key \"count\":\n  expected: 1\n  actual:   0" <>
               ~s(\nmodel step: Peek, result :accepted)
  end

  test "missing step clause" do
    assert message(clean(), [], adapter: ToyAdapterNoReset) ==
             "#{@prefix} 4 (Reset), seed 7: adapter AshQuint.Test.ToyAdapterNoReset " <>
               "has no step/2 clause for `Reset`" <> ~s(\nmodel step: Reset, result :accepted)
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
               "expected {:ok, result, ctx}, {:pending, ctx}, {:skip, ctx}, " <>
               "{:start, op, call, ctx}, {:advance, op, ctx} or {:complete, op, ctx}" <>
               ~s(\nmodel step: Inc %{"by" => 1}, result :accepted)
  end

  test "an {:error, _} return value is a bad return value" do
    assert message(clean(), [], adapter: ErrorReturn) ==
             "#{@prefix} 1 (Inc), seed 7: step/2 returned {:error, :boom}; " <>
               "expected {:ok, result, ctx}, {:pending, ctx}, {:skip, ctx}, " <>
               "{:start, op, call, ctx}, {:advance, op, ctx} or {:complete, op, ctx}" <>
               ~s(\nmodel step: Inc %{"by" => 1}, result :accepted)
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
             "#{@prefix} 1 (Peek), seed 7: system call failed: :boom" <>
               ~s(\nmodel step: Peek, result :accepted)
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
             "#{@prefix} 1 (Inc), seed 7: key \"count\":\n  expected: 1\n  actual:   2" <>
               ~s(\nmodel step: Inc %{"by" => 1}, result :accepted)
  end

  test "run! returns the report" do
    assert %{synced: [_, _, _, _]} = Replay.run!(ToyAdapter, trace(clean()), model: :counter)
  end

  test "perturb mutation fails at that step on that key" do
    assert {:error, %{index: 1, message: message}} =
             run(clean(), [], mutate: {:perturb, 1, "count"})

    assert message ==
             "#{@prefix} 1 (Inc), seed 7: key \"count\":\n" <>
               "  expected: {:ash_quint_mutated, \"count\"}\n  actual:   1" <>
               ~s(\nmodel step: Inc %{"by" => 1}, result :accepted)
  end

  test "drop mutation skips the system call" do
    assert {:error, %{index: 1, message: message}} = run(clean(), [], mutate: {:drop, 1})

    assert message ==
             "#{@prefix} 1 (Inc), seed 7: key \"count\":\n  expected: 1\n  actual:   0" <>
               ~s(\nmodel step: Inc %{"by" => 1}, result :accepted)
  end

  test "a dropped call closes the pending step it would have completed" do
    assert {:error, %{index: 2, message: message}} =
             run([init(), begin(0, 2), commit(2)], [], mutate: {:drop, 2})

    assert message ==
             "#{@prefix} 2 (Commit), seed 7: key \"count\":\n  expected: 2\n  actual:   0" <>
               ~s(\nmodel step: Commit, result :accepted)
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

  describe "finish/2" do
    defp finishing(states, adapter_opts \\ [], opts \\ []) do
      Replay.run(
        Finishing,
        trace(states),
        [model: :counter, adapter_opts: [test: self()] ++ adapter_opts] ++ opts
      )
    end

    defp assert_finished_once do
      assert_received {:finished, ctx, result}
      refute_received {:finished, _ctx, _result}
      {ctx, result}
    end

    test "is called once with :ok and the latest ctx after a passing replay" do
      assert {:ok, _report} = finishing(clean())
      assert {%{steps: 4, count: 0}, :ok} = assert_finished_once()
    end

    test "is called once with the failure after an outcome, state or invariant failure" do
      for {fault, states} <- [
            wrong_code: clean(),
            off_by_one: clean(),
            negative: [init(), inc(1, 1), reset()]
          ] do
        assert {:error, failure} = finishing(states, faults: [fault])
        assert {_ctx, {:error, ^failure}} = assert_finished_once()
      end
    end

    test "gets the ctx of a pending step when the trace ends pending" do
      assert {:error, failure} = finishing([init(), begin(0, 2)])
      assert failure.message =~ "the trace ends with this {:pending, …} step open"
      assert {%{pending: 2}, {:error, ^failure}} = assert_finished_once()
    end

    test "is called after a failure at step 0 and for a dropped call" do
      assert {:error, %{index: 0} = failure} =
               finishing([init(), inc(1, 1)], raise: {:project, 0})

      assert {_ctx, {:error, ^failure}} = assert_finished_once()

      assert {:error, %{index: 1} = failure} = finishing(clean(), [], mutate: {:drop, 1})
      assert {%{steps: 0}, {:error, ^failure}} = assert_finished_once()
    end

    test "is not called when init/2 never ran" do
      assert {:error, %{index: 0}} = finishing([inc(1, 1), inc(2, 1)])
      refute_received {:finished, _ctx, _result}
    end

    test "is called before an exception in step/2 propagates" do
      assert_raise RuntimeError, "step blew up", fn -> finishing(clean(), raise: {:step, 2}) end
      assert {%{steps: 1, count: 1}, {:error, failure}} = assert_finished_once()

      assert %{index: 2, action: "Inc"} = failure

      assert failure.message ==
               "#{@prefix} 2 (Inc), seed 7: step/2 raised: step blew up" <>
                 ~s(\nmodel step: Inc %{"by" => 2}, result :accepted)
    end

    test "is called with the step's ctx before an exception in project/1 propagates" do
      assert_raise RuntimeError, "no connection", fn ->
        finishing(clean(), raise: {:project, 2})
      end

      assert {%{steps: 2, count: 3}, {:error, failure}} = assert_finished_once()

      assert failure.message ==
               "#{@prefix} 2 (Inc), seed 7: project/1 raised: no connection" <>
                 ~s(\nmodel step: Inc %{"by" => 2}, result :accepted)
    end

    test "is called before a throw propagates" do
      assert catch_throw(finishing(clean(), raise: {:throw, 1})) == :thrown
      assert {_ctx, {:error, failure}} = assert_finished_once()

      assert failure.message ==
               "#{@prefix} 1 (Inc), seed 7: step/2 threw :thrown" <>
                 ~s(\nmodel step: Inc %{"by" => 1}, result :accepted)
    end

    test "an {:error, message} fails a passing replay at the last step" do
      assert {:error, %{index: 4, action: "Reset", message: message}} =
               finishing(clean(), finish: {:error, "witness not reached"})

      assert message ==
               "#{@prefix} 4 (Reset), seed 7: finish/2: witness not reached" <>
                 ~s(\nmodel step: Reset, result :accepted)

      assert {_ctx, :ok} = assert_finished_once()

      assert {:error, %{index: 0, action: "Init"}} =
               finishing([init()], finish: {:error, "witness not reached"})
    end

    test "a bad return value fails a passing replay" do
      assert {:error, %{message: message}} = finishing(clean(), finish: :done)

      assert message ==
               "#{@prefix} 4 (Reset), seed 7: finish/2 returned :done; " <>
                 "expected :ok or {:error, message}" <> ~s(\nmodel step: Reset, result :accepted)
    end

    test "on a failing replay, the original failure is kept" do
      assert {:error, failure} =
               finishing(clean(), faults: [:off_by_one], finish: {:error, "ignored"})

      assert failure.index == 1
      refute failure.message =~ "ignored"
    end

    test "its own exception propagates" do
      assert_raise RuntimeError, "cleanup failed", fn -> finishing(clean(), finish: :raise) end

      assert_raise RuntimeError, "cleanup failed", fn ->
        finishing(clean(), faults: [:off_by_one], finish: :raise)
      end
    end

    test "an adapter exception wins over an exception from finish/2" do
      assert_raise RuntimeError, "step blew up", fn ->
        finishing(clean(), raise: {:step, 1}, finish: :raise)
      end

      assert {_ctx, {:error, _failure}} = assert_finished_once()
    end
  end

  describe "the model step line" do
    test "a failure ends with the model step line" do
      assert message(clean(), [:off_by_one]) ==
               "#{@prefix} 1 (Inc), seed 7: key \"count\":\n  expected: 1\n  actual:   2\n" <>
                 ~s(model step: Inc %{"by" => 1}, result :accepted)
    end

    test "the model step line omits empty picks" do
      assert message([init(), peek(1)]) ==
               "#{@prefix} 1 (Peek), seed 7: key \"count\":\n  expected: 1\n  actual:   0\n" <>
                 "model step: Peek, result :accepted"
    end

    test "the model step line omits a missing result" do
      assert message(clean(), [:off_by_one], results: false) ==
               "#{@prefix} 1 (Inc), seed 7: key \"count\":\n  expected: 1\n  actual:   2\n" <>
                 ~s(model step: Inc %{"by" => 1})
    end

    test "the model step line shows a rejection" do
      assert message(clean(), [:wrong_code]) ==
               "#{@prefix} 3 (Inc), seed 7: " <>
                 ~s(outcome: expected {:rejected, "too_big"}, got {:rejected, "other"}\n) <>
                 ~s(model step: Inc %{"by" => 1}, result {:rejected, "too_big"})
    end

    test "a failure at step 0 has no model step line" do
      assert {:error, %{index: 0, message: message}} =
               Replay.run(RaisingProject, trace(clean()),
                 model: :counter,
                 adapter_opts: [raise: :project],
                 context: ["trace: a"]
               )

      assert message == "#{@prefix} 0 (Init), seed 7: project/1 raised: no connection\ntrace: a"
    end

    test "context lines come last" do
      assert message(clean(), [:off_by_one], context: ["trace: a", "quint: b"]) ==
               "#{@prefix} 1 (Inc), seed 7: key \"count\":\n  expected: 1\n  actual:   2\n" <>
                 ~s(model step: Inc %{"by" => 1}, result :accepted\n) <>
                 "trace: a\nquint: b"
    end

    test "no context by default" do
      lines = String.split(message(clean(), [:off_by_one]), "\n")
      assert List.last(lines) == ~s(model step: Inc %{"by" => 1}, result :accepted)
    end
  end
end
