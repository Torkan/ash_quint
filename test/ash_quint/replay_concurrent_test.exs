defmodule AshQuint.ReplayConcurrentTest do
  use ExUnit.Case, async: true

  import AshQuint.Test.TraceBuilder

  alias AshQuint.Gate.Table
  alias AshQuint.Replay
  alias AshQuint.Test.ConcurrentToyAdapter

  @prefix "counter random t, step"

  defp run(states, adapter_opts \\ [], opts \\ []) do
    {trace_opts, opts} = Keyword.split(opts, [:results])

    Replay.run(
      ConcurrentToyAdapter,
      trace(states, trace_opts),
      [model: :counter, adapter_opts: adapter_opts] ++ opts
    )
  end

  defp message(states, adapter_opts \\ [], opts \\ []) do
    assert {:error, %{message: message}} = run(states, adapter_opts, opts)
    message
  end

  # o1 and o2 both start before either returns; o2 returns first.
  defp race do
    [
      init(),
      inc_start(0, "o1", 2),
      inc_start(0, "o2", 2),
      inc_done(2, "o2"),
      inc_done(2, "o1", {:rejected, "too_big"})
    ]
  end

  describe ":start and :complete" do
    test "replays two overlapping incs whose second completes first" do
      assert {:ok, report} = run(race())

      assert [
               %{index: 1, action: "IncStart", kind: :start, op: "o1", expected: %{"count" => 0}},
               %{index: 2, action: "IncStart", kind: :start, op: "o2", expected: %{"count" => 0}},
               %{
                 index: 3,
                 action: "IncDone",
                 kind: :complete,
                 op: "o2",
                 expected: %{"count" => 2}
               },
               %{
                 index: 4,
                 action: "IncDone",
                 kind: :complete,
                 op: "o1",
                 expected: %{"count" => 2}
               }
             ] = report.synced
    end

    test "the :lost_update fault fails at step 4 on the outcome" do
      assert {:error, failure} = run(race(), faults: [:lost_update])
      assert %{index: 4, action: "IncDone"} = failure

      assert failure.message ==
               "#{@prefix} 4 (IncDone), seed 7: op \"o1\" (started at step 1): " <>
                 "outcome: expected {:rejected, \"too_big\"}, got :accepted"
    end

    test "state is compared at start steps" do
      assert {:error, failure} = run(race(), faults: [:visible_early])
      assert %{index: 1, action: "IncStart"} = failure
      assert failure.message =~ "#{@prefix} 1 (IncStart), seed 7: key \"count\":\n"
      assert failure.message =~ "  expected: 0\n  actual:   2"
    end
  end

  describe "the model and the adapter must agree" do
    defp with_result(tag, result) do
      %{
        "count" => 0,
        "lastAction" => {:variant, tag, %{"op" => "o1", "by" => 1}},
        "lastResult" => result
      }
    end

    @pending {:variant, "Pending", {}}
    @accepted {:variant, "Accepted", {}}

    test "a Pending step returning {:ok, …}, {:skip, …} or {:complete, …} is refused" do
      assert message([init(), with_result("Inc", @pending)]) ==
               "#{@prefix} 1 (Inc), seed 7: the model keeps Inc in flight " <>
                 "(lastResult Pending), but step/2 returned {:ok, …}"

      assert message([init(), with_result("Peek", @pending)]) ==
               "#{@prefix} 1 (Peek), seed 7: the model keeps Peek in flight " <>
                 "(lastResult Pending), but step/2 returned {:skip, …}"

      assert message([init(), inc_start(0, "o1", 1), with_result("IncDone", @pending)]) ==
               "#{@prefix} 2 (IncDone), seed 7: the model keeps IncDone in flight " <>
                 "(lastResult Pending), but step/2 returned {:complete, \"o1\", …}\n" <>
                 "in flight: \"o1\" at gate :requested (since step 1)"
    end

    test "a step that isn't Pending returning {:start, …} is refused" do
      assert message([init(), with_result("IncStart", @accepted)]) ==
               "#{@prefix} 1 (IncStart), seed 7: the model completes IncStart here, " <>
                 "but step/2 returned {:start, \"o1\", …}"
    end

    test "complete of an op not in flight lists the ops in flight" do
      states = [init(), inc_start(0, "o1", 1), inc_start(0, "o2", 1), inc_done(1, "o3")]

      assert message(states) ==
               "#{@prefix} 3 (IncDone), seed 7: complete of op \"o3\", which isn't in flight; " <>
                 "in flight: \"o1\", \"o2\""

      assert message([init(), inc_done(1, "o3")]) ==
               "#{@prefix} 1 (IncDone), seed 7: complete of op \"o3\", which isn't in flight; " <>
                 "no op is in flight"
    end

    test "starting an op already in flight is refused" do
      assert message([init(), inc_start(0, "o1", 1), inc_start(0, "o1", 1)]) ==
               "#{@prefix} 2 (IncStart), seed 7: op \"o1\" was started at step 1 and is " <>
                 "started again\nin flight: \"o1\" at gate :requested (since step 1)"
    end

    test "a trace without lastResult: only the not-in-flight row applies" do
      assert {:ok, _report} = run(race(), [], results: false)

      states = [init(), inc_start(0, "o1", 1), inc_done(1, "o3")]
      assert message(states, [], results: false) =~ "complete of op \"o3\", which isn't in flight"

      # No outcome is asserted, but the state still is.
      assert {:ok, _report} = run(race(), [faults: [:lost_update]], results: false)
      assert {:error, failure} = run(race(), [faults: [:visible_early]], results: false)
      assert failure.index == 1
      assert failure.message =~ "key \"count\""
    end
  end

  describe "ops that finish" do
    test "an op that finishes before any gate fails" do
      states = [init(), inc_start(0, "o1", 1), peek(0), inc_done(1, "o1")]

      assert message(states, faults: [:no_gate]) ==
               "#{@prefix} 1 (IncStart), seed 7: op \"o1\" finished before reaching a gate; " <>
                 "the model keeps it in flight until step 3\n" <>
                 "in flight: \"o1\" finished (since step 1)"

      assert message(Enum.take(states, 3), faults: [:no_gate]) =~
               "the model keeps it in flight until a later step"
    end

    test "early: :ok lets it finish; its result is held until the completion step" do
      opts = [faults: [:no_gate], start_opts: %{"o1" => [early: :ok]}]

      assert {:ok, _report} =
               run([init(), inc_start(1, "o1", 1), peek(1), inc_done(1, "o1")], opts)

      assert message([init(), inc_start(1, "o1", 1), inc_done(1, "o1", {:rejected, "x"})], opts) ==
               "#{@prefix} 2 (IncDone), seed 7: op \"o1\" (started at step 1): " <>
                 "outcome: expected {:rejected, \"x\"}, got :accepted"
    end

    test "a raising op fails at the step that observes it" do
      message = message(race(), faults: [{:raise, "o2"}])

      assert message =~
               "#{@prefix} 3 (IncDone), seed 7: op \"o2\" raised: ** (RuntimeError) boom\n"

      assert message =~ "\nin flight: \"o1\" at gate :requested (since step 1)"
    end
  end

  describe ":advance and at:" do
    defp advanced, do: [init(), inc_start(0, "o1", 1), inc_advance(0, "o1"), inc_done(1, "o1")]

    test "advance releases one gate and settles at the next" do
      assert {:ok, report} = run(advanced(), faults: [:two_gates])

      assert Enum.map(report.synced, &{&1.kind, &1.op}) ==
               [start: "o1", advance: "o1", complete: "o1"]

      states = List.replace_at(advanced(), 2, inc_advance(5, "o1"))
      assert {:error, failure} = run(states, faults: [:two_gates])
      assert failure.index == 2
      assert failure.in_flight == [%{op: "o1", started_at: 1, at_gate: :after_read}]
      assert failure.message =~ "in flight: \"o1\" at gate :after_read (since step 2)"
    end

    test "advance with at: names both gates on a mismatch" do
      opts = [faults: [:two_gates], advance_opts: %{"o1" => [at: :before_write]}]

      assert message(advanced(), opts) =~
               "#{@prefix} 2 (IncRead), seed 7: op \"o1\" reached gate :after_read; " <>
                 "the adapter expected :before_write\n"

      opts = [faults: [:two_gates], advance_opts: %{"o1" => [at: :after_read]}]
      assert {:ok, _report} = run(advanced(), opts)
    end

    test "start with at: checks the first gate" do
      states = [init(), inc_start(0, "o1", 1), inc_done(1, "o1")]

      assert message(states, start_opts: %{"o1" => [at: :after_read]}) =~
               "#{@prefix} 1 (IncStart), seed 7: op \"o1\" reached gate :requested; " <>
                 "the adapter expected :after_read\n"

      assert {:ok, _report} = run(states, start_opts: %{"o1" => [at: :requested]})
    end

    test "unknown or malformed start and advance options are refused" do
      states = [init(), inc_start(0, "o1", 1), inc_done(1, "o1")]

      assert message(states, start_opts: %{"o1" => [early: true]}) ==
               "#{@prefix} 1 (IncStart), seed 7: step/2 returned {:start, \"o1\", …} with " <>
                 "options [early: true]; expected early: :ok, may_block: boolean() and at: a gate name"

      opts = [faults: [:two_gates], advance_opts: %{"o1" => [early: :ok]}]

      assert message(advanced(), opts) =~
               "#{@prefix} 2 (IncRead), seed 7: step/2 returned {:advance, \"o1\", …} with " <>
                 "options [early: :ok]; expected may_block: boolean() and at: a gate name\n"
    end

    test "advance must agree with the model and name an op in flight" do
      assert message([init(), inc_advance(0, "o1")]) ==
               "#{@prefix} 1 (IncRead), seed 7: advance of op \"o1\", which isn't in flight; " <>
                 "no op is in flight"

      read = %{inc_advance(0, "o1") | "lastResult" => {:variant, "Accepted", {}}}

      assert message([init(), inc_start(0, "o1", 1), read], faults: [:two_gates]) =~
               "#{@prefix} 2 (IncRead), seed 7: the model completes IncRead here, " <>
                 "but step/2 returned {:advance, \"o1\", …}\n"
    end
  end

  describe "settling" do
    # o1 takes the lock and is held at :after_read; o2 waits for the lock.
    defp locked do
      [
        init(),
        inc_start(0, "o1", 1),
        inc_start(0, "o2", 1),
        inc_done(1, "o1"),
        inc_done(2, "o2")
      ]
    end

    @settle [settle_timeout: 50]

    test "an op that neither gates nor finishes fails" do
      assert message(locked(), [faults: [:locking]], @settle) ==
               "#{@prefix} 2 (IncStart), seed 7: op \"o2\" did not settle within 50ms; " <>
                 "in flight: \"o1\" at gate :after_read (since step 1)"
    end

    test "with may_block: true it counts as blocked and the replay continues" do
      opts = [faults: [:locking], start_opts: %{"o2" => [may_block: true]}]
      assert {:ok, _report} = run(locked(), opts, @settle)

      states = List.replace_at(locked(), 2, inc_start(5, "o2", 1))
      assert {:error, failure} = run(states, opts, @settle)
      assert failure.index == 2
      assert failure.message =~ "\"o2\" blocked (since step 2)"
      assert [%{op: "o1", at_gate: :after_read}, %{op: "o2", at_gate: nil}] = failure.in_flight
    end

    test "an op the adapter reports blocked settles without waiting out the timeout" do
      opts = [faults: [:locking], blocked: true, test: self()]
      started = System.monotonic_time(:millisecond)
      assert {:ok, _report} = run(locked(), opts, settle_timeout: 5_000)
      # The settle timeout is never waited out (blocked?/2 is polled every 10ms).
      assert System.monotonic_time(:millisecond) - started < 2_500

      assert_received {:blocked?, %{op: "o2", pid: pid, started_at: 2, info: %{lock: :mutex}}}
      assert is_pid(pid)

      states = List.replace_at(locked(), 2, inc_start(5, "o2", 1))
      assert {:error, failure} = run(states, opts, settle_timeout: 5_000)
      assert failure.message =~ "\"o2\" blocked (since step 2)"
    end

    test "blocked?/2 raising fails the step like any adapter callback" do
      opts = [faults: [:locking], blocked: :raise, test: self()]

      assert_raise RuntimeError, "blocked? blew up", fn ->
        run(locked(), opts, settle_timeout: 5_000)
      end

      assert_received {:toy_finish, {:error, failure}, alive}

      assert failure.message ==
               "#{@prefix} 2 (IncStart), seed 7: blocked?/2 raised: blocked? blew up"

      assert alive == [false, false]
    end

    test "a blocked op that later reaches a gate is settled there at the next step" do
      opts = [faults: [:locking], start_opts: %{"o2" => [may_block: true]}]
      states = List.replace_at(locked(), 3, inc_done(5, "o1"))

      # Once o1 is released, o2 must reach its gate within the settle
      # timeout; 300ms leaves room for a loaded scheduler.
      assert {:error, failure} = run(states, opts, settle_timeout: 300)
      assert failure.index == 3
      assert failure.in_flight == [%{op: "o2", started_at: 2, at_gate: :after_read}]
      assert failure.message =~ "in flight: \"o2\" at gate :after_read (since step 3)"
    end
  end

  describe "sync steps while ops are in flight" do
    test "a {:skip, …} and an {:ok, …} step between a start and its completion replay and sync" do
      states = [init(), inc_start(0, "o1", 1), peek(0), inc(2, 2), inc_done(3, "o1")]
      assert {:ok, report} = run(states)

      assert Enum.map(report.synced, &{&1.index, &1.kind, &1.op}) == [
               {1, :start, "o1"},
               {2, :skip, nil},
               {3, :ok, nil},
               {4, :complete, "o1"}
             ]
    end

    test "a sync step blocked on a gated op's lock fails" do
      states = [init(), inc_start(0, "o1", 1), peek(0), inc_done(1, "o1")]

      assert message(states, [faults: [:locking, :peek_locks]], step_timeout: 200) =~
               "#{@prefix} 2 (Peek), seed 7: step 2 (Peek) blocked for 200ms while \"o1\" " <>
                 "was held at gate :after_read"
    end

    test "a gate timeout fails the step the replay is on" do
      states = [init(), inc_start(0, "o1", 1), wait_op(0, "o1"), inc_done(1, "o1")]

      assert message(states, [], gate_timeout: 50) =~
               "#{@prefix} 2 (WaitOp), seed 7: gate :requested of op \"o1\" was not released " <>
                 "within 50ms\n"
    end
  end

  describe "the end of the replay" do
    defp own_rows, do: :ets.match_object(Table.name(), {:_, self(), :_, :_, :_, :_, :_})

    test "a trace ending with ops in flight passes; the ops are cancelled unchecked" do
      states = [init(), inc_start(0, "o1", 2), inc_start(0, "o2", 2)]
      assert {:ok, report} = run(states, faults: [:lost_update], test: self())
      assert Enum.map(report.synced, & &1.kind) == [:start, :start]
      assert_received {:toy_finish, :ok, [false, false]}
      assert own_rows() == []
    end

    test "finish/2 runs after every op task is dead, on pass, on failure and before an adapter exception propagates" do
      assert {:ok, _report} = run(race(), test: self())
      assert_received {:toy_finish, :ok, [false, false]}

      assert {:error, _failure} = run(race(), faults: [:lost_update], test: self())
      assert_received {:toy_finish, {:error, %{index: 4}}, [false, false]}

      assert {:error, _failure} = run(Enum.take(race(), 3) ++ [peek(5)], test: self())
      assert_received {:toy_finish, {:error, %{index: 3}}, [false, false]}

      assert_raise RuntimeError, "project blew up", fn ->
        run(race(), faults: [:project_raises], test: self())
      end

      assert_received {:toy_finish, {:error, %{index: 1, message: message}}, [false]}
      assert message =~ "project/1 raised: project blew up"
    end

    test "failure.in_flight lists op, start step and gate" do
      states = [init(), inc_start(0, "o1", 1), inc_start(0, "o2", 1), inc_done(1, "o2"), peek(5)]
      assert {:error, failure} = run(states, faults: [:two_gates])
      assert failure.index == 4
      assert failure.in_flight == [%{op: "o1", started_at: 1, at_gate: :requested}]
      assert failure.message =~ "\nin flight: \"o1\" at gate :requested (since step 1)"

      assert {:error, failure} = run([init(), peek(5)])
      refute Map.has_key?(failure, :in_flight)
      refute failure.message =~ "in flight"
    end

    test "an adapter exception with ops in flight leaves no gate-table rows" do
      assert_raise RuntimeError, fn -> run(race(), faults: [:project_raises]) end
      assert own_rows() == []
      refute_received {:ash_quint_gate, _ref, _op, _name, _pid, _reply}
    end
  end

  describe "{:pending, …} with ops in flight" do
    test "{:pending, …} while ops are in flight is allowed" do
      states = [init(), inc_start(0, "o1", 1), begin(0, 2), commit(2), inc_done(3, "o1")]
      assert {:ok, report} = run(states)

      assert Enum.map(report.synced, &{&1.index, &1.kind}) == [
               {1, :start},
               {3, :ok},
               {4, :complete}
             ]
    end

    test "a second {:pending, …} and {:skip, …} while one is pending are still refused" do
      states = [init(), inc_start(0, "o1", 1), begin(0, 2), begin(0, 1)]

      assert message(states) =~
               "#{@prefix} 3 (Begin), seed 7: interleaved trace: two {:pending, …}"

      assert message(states) =~ "\nin flight: \"o1\" at gate :requested (since step 1)"

      states = [init(), inc_start(0, "o1", 1), begin(0, 2), peek(0)]
      assert message(states) =~ "#{@prefix} 3 (Peek), seed 7: interleaved trace: {:skip, …} while"

      states = [init(), inc_start(0, "o1", 1), begin(0, 2)]
      assert message(states) =~ "#{@prefix} 2 (Begin), seed 7: interleaved trace: the trace ends"
    end
  end

  describe "drops" do
    test "dropping a start makes its completion a skip" do
      states = [init(), inc_start(0, "o1", 2), inc_done(2, "o1")]
      assert {:error, failure} = run(states, [test: self()], mutate: {:drop, 1})

      assert failure.message ==
               "#{@prefix} 2 (IncDone), seed 7: key \"count\":\n  expected: 2\n  actual:   0"

      refute Map.has_key?(failure, :in_flight)
      assert_received {:toy_finish, {:error, %{index: 2}}, []}
    end

    test "a dropped start's advances are skips too" do
      states = [init(), inc_start(0, "o1", 1), inc_advance(0, "o1"), inc_done(1, "o1")]
      assert {:error, failure} = run(states, [faults: [:two_gates]], mutate: {:drop, 1})
      assert %{index: 3, action: "IncDone"} = failure
      assert failure.message =~ "key \"count\":\n  expected: 1\n  actual:   0"
    end

    test "a dropped start syncs as a skip and other ops carry on" do
      assert {:ok, report} = run(race(), [], mutate: {:drop, 1})

      assert Enum.map(report.synced, &{&1.kind, &1.op}) ==
               [skip: nil, start: "o2", complete: "o2", skip: nil]
    end

    test "an op id is started again after its dropped start's completion" do
      states = [
        init(),
        inc_start(0, "o1", 5),
        inc_done(0, "o1", {:rejected, "too_big"}),
        inc_start(0, "o1", 1),
        inc_done(1, "o1")
      ]

      assert {:ok, report} = run(states, [], mutate: {:drop, 1})

      assert Enum.map(report.synced, &{&1.kind, &1.op}) ==
               [skip: nil, skip: nil, start: "o1", complete: "o1"]
    end

    test "dropping a completion fails on state and the op is cancelled at the end" do
      states = [init(), inc_start(0, "o1", 2), inc_done(2, "o1")]
      assert {:error, failure} = run(states, [test: self()], mutate: {:drop, 2})

      assert failure.message ==
               "#{@prefix} 2 (IncDone), seed 7: key \"count\":\n  expected: 2\n  actual:   0\n" <>
                 "in flight: \"o1\" at gate :requested (since step 1)"

      assert failure.in_flight == [%{op: "o1", started_at: 1, at_gate: :requested}]
      assert_received {:toy_finish, {:error, %{index: 2}}, [false]}
    end
  end

  describe "{:serialize, index}" do
    test "a serialized op runs to completion at its start and its outcome is checked at its completion" do
      # WaitOp returns once o1's task has exited, which it has only if o1
      # ran through its gate at its start.
      states = [
        init(),
        inc_start(0, "o1", 5),
        wait_op(0, "o1"),
        inc_done(0, "o1", {:rejected, "too_big"})
      ]

      assert {:ok, report} = run(states, [], mutate: {:serialize, 1}, step_timeout: 200)

      assert Enum.map(report.synced, &{&1.kind, &1.op}) ==
               [start: "o1", skip: nil, complete: "o1"]

      states = List.replace_at(states, 3, inc_done(0, "o1"))
      assert {:error, failure} = run(states, [], mutate: {:serialize, 1}, step_timeout: 200)

      assert failure.message ==
               "#{@prefix} 3 (IncDone), seed 7: op \"o1\" (started at step 1): " <>
                 "outcome: expected :accepted, got {:rejected, \"too_big\"}"
    end

    test "only the op started at the index is serialized" do
      assert {:error, failure} = run(race(), [], mutate: {:serialize, 2})
      assert %{index: 2, action: "IncStart"} = failure
      assert failure.message =~ "key \"count\":\n  expected: 0\n  actual:   2"

      assert failure.in_flight == [
               %{op: "o1", started_at: 1, at_gate: :requested},
               %{op: "o2", started_at: 2, at_gate: nil}
             ]
    end
  end
end
