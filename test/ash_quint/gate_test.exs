defmodule AshQuint.GateTest do
  use ExUnit.Case, async: true

  alias AshQuint.Gate
  alias AshQuint.Gate.Table

  describe "checkpoint/1 outside an op task" do
    test "checkpoint returns :ok at once outside an op task" do
      assert Gate.checkpoint(:after_read) == :ok
      assert Gate.checkpoint({:query, 1}) == :ok
    end

    test "checkpoint returns :ok when the gate table doesn't exist" do
      assert Gate.lookup(:ash_quint_no_such_table, [self()]) == nil
    end

    test "checkpoint never raises" do
      for name <- ["after_read", 1, [], %{}, self(), make_ref()] do
        assert Gate.checkpoint(name) == :ok
      end
    end
  end

  describe "op tasks" do
    setup do
      %{ref: make_ref()}
    end

    defp start(ref, call, opts \\ []) do
      pid = Gate.start_op(ref, "o1", call, opts)
      %{"o1" => %{pid: pid, status: :running}}
    end

    defp settle(ref, ops, timeout \\ 1_000) do
      {ops, []} = Gate.await_settled(ref, ops, timeout)
      ops
    end

    test "an op task stops at a gate and settles there", %{ref: ref} do
      test = self()

      ops =
        start(ref, fn ->
          Gate.checkpoint(:a)
          send(test, :passed_a)
        end)

      ops = settle(ref, ops)
      assert %{status: {:gate, :a, pid, _reply}} = ops["o1"]
      assert pid == ops["o1"].pid
      refute_received :passed_a
      Gate.cancel_all(ref, ops)
    end

    test "release lets it run to the next gate", %{ref: ref} do
      ops =
        start(ref, fn ->
          Gate.checkpoint(:a)
          Gate.checkpoint(:b)
        end)

      ops = ref |> settle(ops) |> Gate.release("o1")
      assert ops["o1"].status == :running
      assert %{status: {:gate, :b, _pid, _reply}} = settle(ref, ops)["o1"]
      Gate.cancel_all(ref, ops)
    end

    test "free runs it through every remaining gate to its result", %{ref: ref} do
      ops =
        start(ref, fn ->
          Gate.checkpoint(:a)
          Gate.checkpoint(:b)
          Gate.checkpoint(:c)
          :result
        end)

      ops = ref |> settle(ops) |> Gate.free("o1")
      assert %{status: {:finished, {:returned, :result}}} = settle(ref, ops)["o1"]
    end

    test "a Task spawned inside the op gates the op ($callers)", %{ref: ref} do
      ops = start(ref, fn -> Task.await(Task.async(fn -> Gate.checkpoint(:inner) end)) end)
      ops = settle(ref, ops)
      assert %{status: {:gate, :inner, gate_pid, _reply}, pid: pid} = ops["o1"]
      assert gate_pid != pid

      ops = Gate.release(ops, "o1")
      assert %{status: {:finished, {:returned, :ok}}} = settle(ref, ops)["o1"]
    end

    test "a raising call becomes {:raised, kind, reason, stacktrace}", %{ref: ref} do
      ops = settle(ref, start(ref, fn -> raise "boom" end))

      assert %{status: {:finished, {:raised, :error, %RuntimeError{message: "boom"}, [_ | _]}}} =
               ops["o1"]

      ops = settle(ref, start(ref, fn -> throw(:up) end))
      assert %{status: {:finished, {:raised, :throw, :up, _stacktrace}}} = ops["o1"]
    end

    test "$callers of the op task is [test_pid | test's $callers]", %{ref: ref} do
      outer = spawn(fn -> :ok end)
      Process.put(:"$callers", [outer])
      ops = settle(ref, start(ref, fn -> Process.get(:"$callers") end))
      assert ops["o1"].status == {:finished, {:returned, [self(), outer]}}
    end

    test "a gate not released within gate_timeout returns and reports the timeout",
         %{ref: ref} do
      ops = start(ref, fn -> Gate.checkpoint(:a) end, gate_timeout: 50)
      ops = settle(ref, ops)
      assert %{status: {:gate, :a, _pid, _reply}} = ops["o1"]

      # The op isn't released: its gate times out and it runs on to its result.
      assert {ops, [{"o1", :a}]} = Gate.await_finished(ref, ops, "o1", 1_000)
      assert ops["o1"].status == {:finished, {:returned, :ok}}
    end
  end

  describe "cancel_all/2" do
    setup do
      %{ref: make_ref()}
    end

    defp rows(ref), do: :ets.match_object(Table.name(), {:_, :_, ref, :_, :_, :_})

    test "cancel_all stops gated, running and finished ops and leaves the test process alive",
         %{ref: ref} do
      test = self()
      gated = Gate.start_op(ref, "gated", fn -> Gate.checkpoint(:a) end, [])

      running =
        Gate.start_op(
          ref,
          "running",
          fn ->
            send(test, :running)
            receive do: (:never -> :ok)
          end,
          []
        )

      finished = Gate.start_op(ref, "finished", fn -> :done end, [])
      assert_receive :running

      ops = %{
        "gated" => %{pid: gated, status: :running},
        "running" => %{pid: running, status: :running},
        "finished" => %{pid: finished, status: :running}
      }

      {ops, []} = Gate.await_settled(ref, ops, 50)
      assert %{status: {:gate, :a, _pid, _reply}} = ops["gated"]
      assert %{status: {:finished, {:returned, :done}}} = ops["finished"]
      assert ops["running"].status == :running

      monitors = for pid <- [gated, running, finished], do: Process.monitor(pid)
      assert Gate.cancel_all(ref, ops) == :ok

      for monitor <- monitors, do: assert_receive({:DOWN, ^monitor, :process, _pid, _reason})
      refute Enum.any?([gated, running, finished], &Process.alive?/1)
      assert Process.alive?(self())
    end

    test "no table rows remain for the replay ref after cancel_all", %{ref: ref} do
      pid = Gate.start_op(ref, "o1", fn -> Gate.checkpoint(:a) end, [])
      Gate.start_op(ref, "o2", fn -> :done end, [])
      assert [_, _] = rows(ref)

      # Cancelling without the replay's ops finds the ops in the table.
      assert Gate.cancel_all(ref, %{}) == :ok
      assert rows(ref) == []
      refute Process.alive?(pid)
      refute_received {:ash_quint_op, ^ref, _op, _result}
      refute_received {:ash_quint_gate, ^ref, _op, _name, _pid, _reply}
    end

    test "killing the test process kills its op tasks", %{ref: ref} do
      test = self()

      fake =
        spawn(fn ->
          pid = Gate.start_op(ref, "o1", fn -> Gate.checkpoint(:a) end, [])
          send(test, {:op, pid})
          receive do: (:never -> :ok)
        end)

      assert_receive {:op, pid}
      monitor = Process.monitor(pid)
      # Signals are ordered only per sender: make sure the monitor is in
      # place before fake's exit signal can reach the op.
      assert {:monitored_by, [_ | _] = monitors} = Process.info(pid, :monitored_by)
      assert self() in monitors
      Process.exit(fake, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    end
  end
end
