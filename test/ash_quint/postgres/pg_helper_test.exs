defmodule AshQuint.Postgres.PgHelperTest do
  use AshQuint.Test.DataCase, unboxed: true

  alias AshQuint.Gate
  alias AshQuint.Test.PgRaceCounter

  setup do
    %{id: id} = Ash.create!(PgRaceCounter, %{id: Ash.UUID.generate()}, action: :open)
    on_exit(fn -> TestRepo.query!("delete from race_counters where id = $1", [dump(id)]) end)
    %{id: id}
  end

  defp dump(id), do: Ecto.UUID.dump!(id)

  # In a transaction: records the backend, locks the row, then gates at :locked.
  defp lock(id) do
    fn ->
      TestRepo.transaction(fn ->
        AshQuint.Ash.pg_backend_pid(TestRepo)
        TestRepo.query!("select id from race_counters where id = $1 for update", [dump(id)])
        Gate.checkpoint(:locked)
      end)
    end
  end

  defp blocked?(_op, entry), do: AshQuint.Ash.pg_blocked?(TestRepo, Gate.info(entry.pid))

  test "an op waiting on a row lock held by a gated op is blocked", %{id: id} do
    ref = make_ref()
    o1 = Gate.start_op(ref, "o1", lock(id), [])
    {ops, []} = Gate.await_settled(ref, %{"o1" => %{pid: o1, status: :running}}, 1_000)
    assert {:gate, :locked, _pid, _reply} = ops["o1"].status

    o2 = Gate.start_op(ref, "o2", lock(id), [])
    ops = Map.put(ops, "o2", %{pid: o2, status: :running})
    {ops, []} = Gate.await_settled(ref, ops, 5_000, &blocked?/2)
    assert ops["o2"].status == :blocked
    assert %{backend_pid: backend} = Gate.info(o2)
    assert AshQuint.Ash.pg_blocked?(TestRepo, backend)

    # Released, o1 commits; o2 takes the lock and reaches its gate. o2 is
    # awaited again from the release on (as the replay wakes blocked ops),
    # since its gate message may arrive while o1 is awaited.
    ops = %{ops | "o2" => %{ops["o2"] | status: :running}}
    {ops, []} = Gate.await_finished(ref, Gate.release(ops, "o1"), "o1", 1_000)
    {ops, []} = Gate.await_settled(ref, ops, 1_000)
    assert {:gate, :locked, _pid, _reply} = ops["o2"].status
    refute AshQuint.Ash.pg_blocked?(TestRepo, Gate.info(o2))
    Gate.cancel_all(ref, ops)
  end

  test "a running op is not blocked", %{id: id} do
    ref = make_ref()
    o1 = Gate.start_op(ref, "o1", lock(id), [])
    {ops, []} = Gate.await_settled(ref, %{"o1" => %{pid: o1, status: :running}}, 1_000)
    assert {:gate, :locked, _pid, _reply} = ops["o1"].status

    refute AshQuint.Ash.pg_blocked?(TestRepo, Gate.info(o1))
    Gate.cancel_all(ref, ops)
  end

  test "an op that recorded no backend is not blocked" do
    refute AshQuint.Ash.pg_blocked?(TestRepo, %{})
    refute AshQuint.Ash.pg_blocked?(TestRepo, %{op: "o1", pid: self(), started_at: 1, info: %{}})
  end

  test "pg_backend_pid/1 outside an op task returns the backend pid" do
    assert is_integer(AshQuint.Ash.pg_backend_pid(TestRepo))
  end
end
