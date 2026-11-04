defmodule AshQuint.Postgres.TelemetryTest do
  use AshQuint.Test.DataCase, async: true

  alias AshQuint.Gate
  alias AshQuint.Gate.Telemetry

  test "an Ecto query event gates the op between statements" do
    ref = make_ref()
    handler = Telemetry.attach([[:ash_quint, :test_repo, :query]], replay: ref)
    on_exit(fn -> Telemetry.detach(handler) end)

    call = fn ->
      TestRepo.query!("create temporary table seen (n int)")
      TestRepo.query!("insert into seen values (1)")
      TestRepo.query!("select n from seen").rows
    end

    pid = Gate.start_op(ref, "o1", call, [])
    ops = %{"o1" => %{pid: pid, status: :running}}

    {ops, []} = Gate.await_settled(ref, ops, 1_000)
    assert {:gate, {:query, 1}, _pid, _reply} = ops["o1"].status

    {ops, []} = Gate.await_settled(ref, Gate.release(ops, "o1"), 1_000)
    assert {:gate, {:query, 2}, _pid, _reply} = ops["o1"].status
    # The op's insert ran; the test shares its sandbox connection.
    assert TestRepo.query!("select n from seen").rows == [[1]]

    {ops, []} = Gate.await_settled(ref, Gate.release(ops, "o1"), 1_000)
    assert {:gate, {:query, 3}, _pid, _reply} = ops["o1"].status

    {ops, []} = Gate.await_finished(ref, Gate.release(ops, "o1"), "o1", 1_000)
    assert ops["o1"].status == {:finished, {:returned, [[1]]}}
    Gate.cancel_all(ref, ops)
  end
end
