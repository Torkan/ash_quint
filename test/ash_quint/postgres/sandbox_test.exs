defmodule AshQuint.Postgres.SandboxHelpers do
  @moduledoc false
  # Raw SQL on race_counters, through AshQuint.TestRepo.

  alias AshQuint.TestRepo

  def open do
    id = Ecto.UUID.generate()
    TestRepo.query!("insert into race_counters (id) values ($1)", [dump(id)])
    id
  end

  def count(id) do
    %{rows: [[count]]} =
      TestRepo.query!("select count from race_counters where id = $1", [dump(id)])

    count
  end

  def set(id, count),
    do: TestRepo.query!("update race_counters set count = $2 where id = $1", [dump(id), count])

  def delete(id), do: TestRepo.query!("delete from race_counters where id = $1", [dump(id)])

  def dump(id), do: Ecto.UUID.dump!(id)
end

defmodule AshQuint.Postgres.SharedSandboxTest do
  # §5.5, shared sandbox: op tasks use the test's one connection (through
  # $callers), inside its one wrapping transaction.
  use AshQuint.Test.DataCase, async: true

  import AshQuint.Postgres.SandboxHelpers
  import AshQuint.Test.TraceBuilder

  alias AshQuint.{Gate, Replay}
  alias AshQuint.Test.PgOpsAdapter

  test "ops' separate statements interleave and a read-modify-write across two transactions loses an update" do
    id = open()

    # Reads in one transaction, gates, writes read + 1 in another.
    inc = fn ->
      {:ok, read} = TestRepo.transaction(fn -> count(id) end)
      Gate.checkpoint(:after_read)
      {:ok, _} = TestRepo.transaction(fn -> set(id, read + 1) end)
      read + 1
    end

    ref = make_ref()
    o1 = Gate.start_op(ref, "o1", inc, [])
    {ops, []} = Gate.await_settled(ref, %{"o1" => %{pid: o1, status: :running}}, 1_000)
    o2 = Gate.start_op(ref, "o2", inc, [])
    {ops, []} = Gate.await_settled(ref, Map.put(ops, "o2", %{pid: o2, status: :running}), 1_000)

    assert {:gate, :after_read, _, _} = ops["o1"].status
    assert {:gate, :after_read, _, _} = ops["o2"].status

    {ops, []} = Gate.await_finished(ref, Gate.release(ops, "o1"), "o1", 1_000)
    {ops, []} = Gate.await_finished(ref, Gate.release(ops, "o2"), "o2", 1_000)

    assert ops["o1"].status == {:finished, {:returned, 1}}
    assert ops["o2"].status == {:finished, {:returned, 1}}
    assert count(id) == 1
    Gate.cancel_all(ref, ops)
  end

  test "an op gated inside Repo.transaction makes the next op time out settling, and the failure names the gate" do
    id = open()

    in_tx = fn ->
      TestRepo.transaction(fn ->
        count(id)
        Gate.checkpoint(:in_tx)
      end)
    end

    states = [init(), inc_start(0, "o1", 1), inc_start(0, "o2", 1)]

    assert {:error, failure} =
             Replay.run(PgOpsAdapter, trace(states),
               model: :counter,
               adapter_opts: [calls: %{"o1" => in_tx, "o2" => fn -> count(id) end}],
               settle_timeout: 200
             )

    assert failure.index == 2

    assert failure.message =~
             "op \"o2\" did not settle within 200ms; " <>
               "in flight: \"o1\" at gate :in_tx (since step 1)"
  end
end

defmodule AshQuint.Postgres.UnboxedTest do
  # §5.5, unboxed: each op task checks out a connection of its own, so row
  # locks are real. Rows are committed; each test deletes its own.
  use AshQuint.Test.DataCase, unboxed: true

  import AshQuint.Postgres.SandboxHelpers
  import AshQuint.Test.TraceBuilder

  alias AshQuint.{Gate, Replay}
  alias AshQuint.Test.PgOpsAdapter

  setup do
    id = open()
    on_exit(fn -> delete(id) end)
    %{id: id}
  end

  # In a transaction: records its backend, locks the row, gates at :locked,
  # then writes count + 1.
  defp locking_inc(id) do
    fn ->
      TestRepo.transaction(fn ->
        AshQuint.Ash.pg_backend_pid(TestRepo)

        %{rows: [[count]]} =
          TestRepo.query!("select count from race_counters where id = $1 for update", [dump(id)])

        Gate.checkpoint(:locked)
        set(id, count + 1)
      end)
    end
  end

  test "two ops each in a transaction, one blocked on the other's row lock, are reported blocked via pg_blocking_pids",
       %{id: id} do
    states = [
      init(),
      inc_start(0, "o1", 1),
      inc_start(0, "o2", 1),
      inc_done(0, "o1"),
      inc_done(0, "o2")
    ]

    calls = %{"o1" => locking_inc(id), "o2" => locking_inc(id)}
    started = System.monotonic_time(:millisecond)

    assert {:ok, _report} =
             Replay.run(PgOpsAdapter, trace(states),
               model: :counter,
               adapter_opts: [calls: calls, blocked: true],
               settle_timeout: 5_000
             )

    # o2 settled as blocked without waiting out the settle timeout.
    assert System.monotonic_time(:millisecond) - started < 2_500
    assert count(id) == 2

    # Without blocked?/2, o2 doesn't settle.
    assert {:error, failure} =
             Replay.run(PgOpsAdapter, trace(states),
               model: :counter,
               adapter_opts: [calls: calls],
               settle_timeout: 100
             )

    assert failure.message =~ "op \"o2\" did not settle within 100ms"
  end

  test "cancel rolls back an op's open transaction", %{id: id} do
    write = fn ->
      TestRepo.transaction(fn ->
        set(id, 99)
        Gate.checkpoint(:written)
      end)
    end

    # The trace ends with o1 in flight: it is cancelled at its gate.
    states = [init(), inc_start(0, "o1", 1)]

    assert {:ok, _report} =
             Replay.run(PgOpsAdapter, trace(states),
               model: :counter,
               adapter_opts: [calls: %{"o1" => write}]
             )

    assert count(id) == 0
    # The row lock is gone too: this update doesn't wait.
    {:ok, _} =
      TestRepo.transaction(fn ->
        TestRepo.query!("set local lock_timeout = 1000")
        set(id, 5)
      end)

    assert count(id) == 5
  end
end
