defmodule AshQuint.Replay.OpsTest do
  # AshQuint.Replay.Ops on hand-made messages, for orderings the replay
  # tests can't force.
  use ExUnit.Case, async: true

  alias AshQuint.Replay.Ops
  alias AshQuint.Step

  @timeouts %{settle: 50, step: 200, complete: 200, gate: 5_000}

  test "an op that reaches a gate while another completes takes its status at that step" do
    ref = make_ref()
    o1 = spawn(fn -> :ok end)
    o2 = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(o2, :kill) end)

    ops = %{
      "o1" => %{
        pid: o1,
        started_at: 1,
        since: 1,
        status: {:gate, :after_read, self(), make_ref()},
        opts: []
      },
      "o2" => %{pid: o2, started_at: 2, since: 2, status: :blocked, opts: [may_block: true]}
    }

    # o1's release unblocks o2, whose gate message arrives before o1's
    # result.
    send(self(), {:ash_quint_gate, ref, "o2", :after_read, self(), make_ref()})
    send(self(), {:ash_quint_op, ref, "o1", {:returned, {:ok, 1}}})

    step = %Step{index: 3, action_taken: "IncDone", nondet_picks: %{}, result: nil, state: %{}}
    assert {ops, {:returned, {:ok, 1}}, []} = Ops.complete(ref, @timeouts, ops, step, "o1")
    assert %{"o2" => %{status: {:gate, :after_read, _pid, _reply}, since: 3}} = ops
    assert Map.keys(ops) == ["o2"]
  end
end
