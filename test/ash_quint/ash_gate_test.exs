defmodule AshQuint.AshGateTest do
  use ExUnit.Case, async: true

  alias AshQuint.Gate
  alias AshQuint.Test.RaceCounter

  # RaceCounter's :inc_atomic is gated by `change {AshQuint.Ash.Gate, at: :requested}`.
  defp open, do: Ash.create!(RaceCounter, %{id: Ash.UUID.generate()}, action: :open)

  defp inc(id), do: RaceCounter |> Ash.get!(id) |> Ash.update(%{by: 1}, action: :inc_atomic)

  test "the change gates an ETS-backed update in an op task" do
    %{id: id} = open()
    ref = make_ref()
    pid = Gate.start_op(ref, "o1", fn -> inc(id) end, [])
    ops = %{"o1" => %{pid: pid, status: :running}}

    {ops, []} = Gate.await_settled(ref, ops, 1_000)
    assert {:gate, :requested, _pid, _reply} = ops["o1"].status
    assert Ash.get!(RaceCounter, id).count == 0

    {ops, []} = Gate.await_finished(ref, Gate.release(ops, "o1"), "o1", 1_000)
    assert {:finished, {:returned, {:ok, %{count: 1}}}} = ops["o1"].status
    assert Ash.get!(RaceCounter, id).count == 1

    Gate.cancel_all(ref, ops)
  end

  test "the change is a no-op outside an op task" do
    %{id: id} = open()
    assert {:ok, %{count: 1}} = inc(id)
  end

  test "at: is required and must be an atom" do
    assert {:error, _} = AshQuint.Ash.Gate.init([])
    assert {:error, _} = AshQuint.Ash.Gate.init(at: "after_read")
    assert {:ok, [at: :after_read]} = AshQuint.Ash.Gate.init(at: :after_read)
  end
end
