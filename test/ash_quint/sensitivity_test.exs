defmodule AshQuint.SensitivityTest do
  use ExUnit.Case, async: true

  import AshQuint.Test.TraceBuilder

  alias AshQuint.Sensitivity

  alias AshQuint.Test.{
    PostconditionToyAdapter,
    ToyAdapter,
    ToyAdapterBlindReset,
    ToyAdapterCounts,
    ToyAdapterLimit
  }

  defmodule TickAdapter do
    @moduledoc false
    # The toy adapter plus a no-op system call for "Tick", which only changes
    # the model's "ticks"; the projection leaves "ticks" out.
    use AshQuint.Adapter

    alias AshQuint.Step

    @impl true
    defdelegate init(trace, opts), to: ToyAdapter

    @impl true
    def step(ctx, %Step{action_taken: "Tick"}), do: {:ok, {:ok, ctx.count}, ctx}
    def step(ctx, step), do: ToyAdapter.step(ctx, step)

    @impl true
    defdelegate project(ctx), to: ToyAdapter

    @impl true
    defdelegate outcome(result), to: ToyAdapter
  end

  defmodule StrictReadAdapter do
    @moduledoc false
    # The toy adapter whose system can't be read while a write is pending.
    use AshQuint.Adapter

    @impl true
    defdelegate init(trace, opts), to: ToyAdapter

    @impl true
    defdelegate step(ctx, step), to: ToyAdapter

    @impl true
    def project(%{pending: nil} = ctx), do: ToyAdapter.project(ctx)
    def project(_ctx), do: raise("read while a write is pending")

    @impl true
    defdelegate outcome(result), to: ToyAdapter
  end

  defmodule MixedAdapter do
    @moduledoc false
    # The toy adapter (with its project/1) plus a postcondition reset_ran
    # that checks step/2 ran for a Reset; blind with the :blind_post fault.
    use AshQuint.Adapter

    alias AshQuint.Step

    @impl true
    defdelegate init(trace, opts), to: ToyAdapter

    @impl true
    def step(ctx, %Step{action_taken: action} = step) do
      with {:ok, result, ctx} <- ToyAdapter.step(ctx, step),
           do: {:ok, result, Map.put(ctx, :last, action)}
    end

    @impl true
    defdelegate project(ctx), to: ToyAdapter

    @impl true
    defdelegate outcome(result), to: ToyAdapter

    @impl true
    def postconditions, do: [reset_ran: &reset_ran/2]

    defp reset_ran(ctx, %Step{action_taken: "Reset"}) do
      if :blind_post in ctx.faults or ctx[:last] == "Reset",
        do: :ok,
        else: {:error, "step/2 didn't run"}
    end

    defp reset_ran(_ctx, _step), do: :ok
  end

  defmodule BlindCommitAdapter do
    @moduledoc false
    # The toy adapter whose expected/2 takes a Commit's count from the
    # system instead of the model, so a dropped Commit goes unnoticed.
    use AshQuint.Adapter

    alias AshQuint.Step

    @impl true
    defdelegate init(trace, opts), to: ToyAdapter

    @impl true
    defdelegate step(ctx, step), to: ToyAdapter

    @impl true
    defdelegate project(ctx), to: ToyAdapter

    @impl true
    def expected(ctx, %Step{action_taken: "Commit"}), do: %{"count" => ctx.count}
    def expected(_ctx, %Step{state: state}), do: Map.take(state, ["count"])

    @impl true
    defdelegate outcome(result), to: ToyAdapter
  end

  defmodule ExtraExpectedAdapter do
    @moduledoc false
    # The tick adapter whose expected/2 also returns the unprojected "ticks".
    use AshQuint.Adapter

    @impl true
    defdelegate init(trace, opts), to: TickAdapter

    @impl true
    defdelegate step(ctx, step), to: TickAdapter

    @impl true
    defdelegate project(ctx), to: TickAdapter

    @impl true
    def expected(_ctx, %AshQuint.Step{state: state}), do: Map.take(state, ["count", "ticks"])

    @impl true
    defdelegate outcome(result), to: TickAdapter
  end

  defmodule LeakyAdapter do
    @moduledoc false
    # The toy adapter with its count in the process dictionary, which init/2
    # doesn't reset: an unscoped projection that sees earlier replays.
    use AshQuint.Adapter

    @impl true
    def init(trace, opts) do
      {:ok, ctx} = ToyAdapter.init(trace, opts)
      {:ok, %{ctx | count: Process.get(__MODULE__, 0)}}
    end

    @impl true
    def step(ctx, step) do
      with {:ok, result, ctx} <- ToyAdapter.step(ctx, step) do
        Process.put(__MODULE__, ctx.count)
        {:ok, result, ctx}
      end
    end

    @impl true
    defdelegate project(ctx), to: ToyAdapter

    @impl true
    defdelegate outcome(result), to: ToyAdapter
  end

  defmodule ResourceAdapter do
    @moduledoc false
    # The strict-read adapter holding resources counted in opts[:open], a
    # :counters ref: init/2 opens one, Begin another that Commit releases,
    # and finish/2 releases what ctx still holds. Slot 2 counts finish/2
    # calls.
    use AshQuint.Adapter

    alias AshQuint.Step

    @impl true
    def init(trace, opts) do
      {:ok, ctx} = StrictReadAdapter.init(trace, opts)
      ref = Keyword.fetch!(opts, :open)
      :counters.add(ref, 1, 1)
      {:ok, Map.merge(ctx, %{ref: ref, held: 1})}
    end

    @impl true
    def step(ctx, %Step{action_taken: "Begin"} = step) do
      :counters.add(ctx.ref, 1, 1)
      StrictReadAdapter.step(%{ctx | held: ctx.held + 1}, step)
    end

    def step(ctx, %Step{action_taken: "Commit"} = step) do
      :counters.sub(ctx.ref, 1, 1)
      StrictReadAdapter.step(%{ctx | held: ctx.held - 1}, step)
    end

    def step(ctx, step), do: StrictReadAdapter.step(ctx, step)

    @impl true
    defdelegate project(ctx), to: StrictReadAdapter

    @impl true
    defdelegate outcome(result), to: StrictReadAdapter

    @impl true
    def finish(ctx, _result) do
      :counters.sub(ctx.ref, 1, ctx.held)
      :counters.add(ctx.ref, 2, 1)
      :ok
    end
  end

  defp check(adapter, states_list, faults \\ []) do
    traces = Enum.map(states_list, &trace/1)
    Sensitivity.check(adapter, traces, model: :counter, adapter_opts: [faults: faults])
  end

  defp tick(count, ticks) do
    %{
      "count" => count,
      "ticks" => ticks,
      "lastAction" => {:variant, "Tick", {}},
      "lastResult" => {:variant, "Accepted", {}}
    }
  end

  defp with_ticks(state, ticks), do: Map.put(state, "ticks", ticks)
  defp with_limit(state), do: Map.put(state, "limit", 3)

  test "a full adapter has no survivors" do
    states = [init(), inc(1, 1), inc(3, 2), inc(3, 1, {:rejected, "too_big"}), reset()]

    assert check(ToyAdapter, [states]) == %{
             never_overlap: [],
             survived: [],
             untested: [],
             tested: [{:key, "count"}, {:call, "Inc"}, {:call, "Reset"}, {:var, "count"}]
           }
  end

  test "unprojected variable: perturbation detected, dropped call untested" do
    states = [
      with_ticks(init(), 0),
      with_ticks(inc(1, 1), 0),
      tick(1, 1),
      with_ticks(inc(2, 1), 1)
    ]

    assert %{survived: [], untested: [{:call, "Tick"}, {:var, "ticks"}], tested: tested} =
             check(TickAdapter, [states])

    assert {:key, "count"} in tested
    refute {:key, "ticks"} in tested
  end

  test "keys expected/2 returns but project/1 doesn't are not mutated" do
    states = [
      with_ticks(init(), 0),
      with_ticks(inc(1, 1), 0),
      tick(1, 1),
      with_ticks(inc(2, 1), 1)
    ]

    assert check(ExtraExpectedAdapter, [states]) == %{
             never_overlap: [],
             survived: [],
             untested: [{:call, "Tick"}, {:var, "ticks"}],
             tested: [{:key, "count"}, {:call, "Inc"}, {:var, "count"}]
           }
  end

  test "a perturbation that fails at an earlier step survives" do
    # The clean replay leaves count 1 behind, so every mutant fails at the
    # Peek at step 1, before its own step 2.
    Process.delete(LeakyAdapter)
    states = [init(), peek(0), inc(1, 1)]

    assert check(LeakyAdapter, [states]) == %{
             never_overlap: [],
             survived: [{:perturb, "random t", 2, "count"}, {:drop, "random t", 2, "Inc"}],
             untested: [],
             tested: [{:key, "count"}, {:call, "Inc"}, {:var, "count"}]
           }
  end

  test "a perturbed long map is still caught" do
    states =
      Enum.map([init(), inc(1, 1), inc(3, 2), reset()], &ToyAdapterCounts.with_counts/1)

    assert check(ToyAdapterCounts, [states]) == %{
             never_overlap: [],
             survived: [],
             untested: [{:var, "count"}],
             tested: [
               {:key, "counts"},
               {:call, "Inc"},
               {:call, "Reset"},
               {:var, "counts"}
             ]
           }
  end

  test "a model variable no projection covers is untested" do
    states = [
      with_ticks(init(), 0),
      with_ticks(inc(1, 1), 0),
      tick(1, 1),
      with_ticks(inc(2, 1), 1)
    ]

    assert %{untested: [{:call, "Tick"}, {:var, "ticks"}], tested: tested} =
             check(TickAdapter, [states])

    assert {:var, "count"} in tested
  end

  test "the action and result roots are not model variables" do
    states = [init(), inc(1, 1), reset()]
    %{untested: untested, tested: tested} = check(ToyAdapter, [states])
    targets = untested ++ tested

    refute {:var, "lastAction"} in targets
    refute {:var, "lastResult"} in targets

    renamed =
      Enum.map(states, fn state ->
        {action, state} = Map.pop(state, "lastAction")
        Map.put(state, "act", action)
      end)

    assert %{untested: untested, tested: tested} =
             Sensitivity.check(ToyAdapter, [trace(renamed)],
               model: :counter,
               action_path: ["act"]
             )

    refute {:var, "act"} in (untested ++ tested)
    assert {:var, "count"} in tested
  end

  test "projected keys that aren't model variables are ignored" do
    %{untested: untested, tested: tested} =
      check(ToyAdapterLimit, [[init(), inc(1, 1), reset()]])

    refute Enum.any?(untested ++ tested, &match?({:var, "limit"}, &1))
    assert {:var, "count"} in tested
  end

  test "constant key is untested" do
    states = Enum.map([init(), inc(1, 1), reset()], &with_limit/1)

    assert %{survived: [], untested: [{:key, "limit"}]} = check(ToyAdapterLimit, [states])
  end

  test "rejected first call is not chosen for drop" do
    states = [init(), inc(0, 5, {:rejected, "too_big"}), inc(1, 1)]

    assert %{
             survived: [],
             untested: [],
             tested: [{:key, "count"}, {:call, "Inc"}, {:var, "count"}]
           } = check(ToyAdapter, [states])
  end

  test "a later trace supplies the mutant when the first changes nothing" do
    quiet = [init(), peek(0)]
    busy = [init(), inc(2, 2), reset()]

    assert %{survived: [], untested: []} = check(ToyAdapter, [quiet, busy])
  end

  test "an undetected dropped call survives" do
    states = [init(), inc(1, 1), reset()]

    assert check(ToyAdapterBlindReset, [states]) == %{
             never_overlap: [],
             survived: [{:drop, "random t", 2, "Reset"}],
             untested: [],
             tested: [{:key, "count"}, {:call, "Inc"}, {:call, "Reset"}, {:var, "count"}]
           }
  end

  test "a dropped Commit is detected through the state" do
    states = [init(), begin(0, 2), commit(2)]

    assert check(ToyAdapter, [states]) == %{
             never_overlap: [],
             survived: [],
             untested: [],
             tested: [{:key, "count"}, {:call, "Commit"}, {:var, "count"}]
           }
  end

  test "a dropped Commit is not detected by the pending step it leaves open" do
    states = [init(), begin(0, 2), commit(2)]

    assert %{survived: [{:drop, "random t", 2, "Commit"}]} = check(BlindCommitAdapter, [states])
  end

  test "a crashing mutant counts as detected" do
    states = [init(), begin(0, 2), commit(2)]

    assert %{survived: [], untested: []} = check(StrictReadAdapter, [states])
  end

  test "every clean and mutant replay is finished, releasing its resources" do
    open = :counters.new(2, [])

    traces = [
      trace([init(), inc(1, 1), inc(3, 2), reset()]),
      trace([init(), begin(0, 2), commit(2)])
    ]

    # Clean replays, perturbed "count" (failing), dropped Inc and Reset
    # (failing), dropped Commit (raising in project/1).
    assert %{survived: [], untested: [], tested: tested} =
             Sensitivity.check(ResourceAdapter, traces,
               model: :counter,
               adapter_opts: [open: open]
             )

    assert tested == [
             {:key, "count"},
             {:call, "Commit"},
             {:call, "Inc"},
             {:call, "Reset"},
             {:var, "count"}
           ]

    assert :counters.get(open, 1) == 0
    # One finish per clean replay and per mutant (every target but the var).
    assert :counters.get(open, 2) == length(traces) + 4
  end

  test "failing clean replay is refused" do
    error =
      assert_raise ArgumentError, fn ->
        check(ToyAdapter, [[init(), inc(1, 1)]], [:off_by_one])
      end

    assert error.message ==
             "sensitivity needs passing replays; " <>
               "counter random t, step 1 (Inc), seed 7: key \"count\":\n" <>
               "  expected: 1\n  actual:   2" <>
               ~s(\nmodel step: Inc %{"by" => 1}, result :accepted)
  end

  test "format/1" do
    result = %{
      survived: [{:perturb, "random t", 1, "count"}, {:drop, "random t", 1, "Inc"}],
      untested: [{:key, "limit"}, {:call, "Peek"}],
      tested: [],
      never_overlap: []
    }

    assert Sensitivity.format(result) ==
             """
             perturbed "count" at random t step 1 was not detected
             dropped Inc at random t step 1 was not detected
             key "limit" never changes in any trace
             no step of Peek changes the state\
             """
  end

  test "format names the variable" do
    result = %{survived: [], untested: [{:var, "inflight"}], never_overlap: []}
    assert Sensitivity.format(result) == ~s(variable "inflight" is never projected)
  end

  describe "postcondition adapters" do
    test "a postcondition that sees a dropped call tests the action" do
      assert check(PostconditionToyAdapter, [[init(), inc(1, 1), reset()]]) == %{
               never_overlap: [],
               survived: [],
               untested: [],
               tested: [{:call, "Inc"}, {:call, "Reset"}]
             }
    end

    test "a postcondition blind to a dropped call leaves it untested" do
      assert check(PostconditionToyAdapter, [[init(), inc(1, 1), reset()]], [:blind_post]) == %{
               never_overlap: [],
               survived: [],
               untested: [{:call, "Inc"}, {:call, "Reset"}],
               tested: []
             }
    end

    test "with project/1, only actions that never change the state get one" do
      states = [init(), reset(), inc(1, 1)]

      assert check(MixedAdapter, [states]) == %{
               never_overlap: [],
               survived: [],
               untested: [],
               tested: [{:key, "count"}, {:call, "Inc"}, {:call, "Reset"}, {:var, "count"}]
             }

      assert check(MixedAdapter, [states], [:blind_post]) == %{
               never_overlap: [],
               survived: [],
               untested: [{:call, "Reset"}],
               tested: [{:key, "count"}, {:call, "Inc"}, {:var, "count"}]
             }
    end

    test "a rejected call gets no postcondition mutant" do
      states = [init(), inc(0, 4, {:rejected, "too_big"}), reset()]

      assert check(PostconditionToyAdapter, [states]) == %{
               never_overlap: [],
               survived: [],
               untested: [{:call, "Inc"}, {:call, "Reset"}],
               tested: []
             }
    end

    test "the first accepted call is dropped, in any trace" do
      rejected = [init(), inc(0, 4, {:rejected, "too_big"})]
      accepted = [init(), peek(0), inc(1, 1)]

      assert check(PostconditionToyAdapter, [rejected, accepted]) == %{
               never_overlap: [],
               survived: [],
               untested: [],
               tested: [{:call, "Inc"}]
             }
    end
  end
end
