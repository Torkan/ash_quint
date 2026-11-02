defmodule AshQuint.StepTest do
  use ExUnit.Case, async: true

  alias AshQuint.Step

  defp state(action, result \\ {:variant, "Accepted", {}}) do
    %{"count" => 3, "lastAction" => action, "lastResult" => result}
  end

  test "record picks" do
    assert {:ok, %Step{index: 1, action_taken: "Inc", nondet_picks: %{"by" => 2}}} =
             Step.from_state(state({:variant, "Inc", %{"by" => 2}}), 1, [])
  end

  test "scalar picks" do
    assert {:ok, %Step{action_taken: "SetTo", nondet_picks: %{"value" => 1}}} =
             Step.from_state(state({:variant, "SetTo", 1}), 1, [])
  end

  test "a set is a scalar pick, not a record" do
    picks = MapSet.new([1, 2])

    assert {:ok, %Step{action_taken: "Add", nondet_picks: %{"value" => ^picks}}} =
             Step.from_state(state({:variant, "Add", picks}), 1, [])
  end

  test "unit picks" do
    assert {:ok, %Step{action_taken: "Reset", nondet_picks: %{}}} =
             Step.from_state(state({:variant, "Reset", {}}), 1, [])
  end

  test "Accepted and Rejected map to outcomes" do
    action = {:variant, "Reset", {}}

    assert {:ok, %Step{result: :accepted}} = Step.from_state(state(action), 1, [])

    assert {:ok, %Step{result: {:rejected, "too_big"}}} =
             Step.from_state(state(action, {:variant, "Rejected", "too_big"}), 1, [])
  end

  test "absent lastResult gives nil" do
    state = %{"count" => 3, "lastAction" => {:variant, "Reset", {}}}
    assert {:ok, %Step{result: nil, state: %{"count" => 3}}} = Step.from_state(state, 1, [])
  end

  test "state excludes the action and result variables" do
    assert {:ok, %Step{state: state}} = Step.from_state(state({:variant, "Reset", {}}), 2, [])
    assert state == %{"count" => 3}
  end

  test "custom paths" do
    state = %{
      "count" => 1,
      "last" => %{
        "action" => {:variant, "Inc", %{"by" => 1}},
        "result" => {:variant, "Rejected", "nope"}
      }
    }

    assert {:ok, step} =
             Step.from_state(state, 4,
               action_path: ["last", "action"],
               result_path: ["last", "result"]
             )

    assert step == %Step{
             index: 4,
             action_taken: "Inc",
             nondet_picks: %{"by" => 1},
             result: {:rejected, "nope"},
             state: %{"count" => 1}
           }
  end

  test "custom paths name the path in errors" do
    assert Step.from_state(%{"last" => 1}, 1, action_path: ["last", "action"]) ==
             {:error, "no action at last.action"}
  end

  test "missing action" do
    assert Step.from_state(%{"count" => 3}, 1, []) == {:error, "no action at lastAction"}
  end

  test "action not a variant" do
    assert Step.from_state(%{"lastAction" => 3}, 1, []) ==
             {:error, "action at lastAction is not a variant: 3"}
  end

  test "unexpected result shape" do
    assert Step.from_state(state({:variant, "Reset", {}}, {:variant, "Maybe", {}}), 1, []) ==
             {:error,
              "result at lastResult must be Accepted or Rejected(str), got {:variant, \"Maybe\", {}}"}

    assert Step.from_state(state({:variant, "Reset", {}}, {:variant, "Rejected", 1}), 1, []) ==
             {:error,
              "result at lastResult must be Accepted or Rejected(str), got {:variant, \"Rejected\", 1}"}
  end

  test "builds steps from the real run fixture" do
    trace = AshQuint.ITF.read!("test/fixtures/itf/run.itf.json")

    steps =
      for {state, index} <- Enum.with_index(trace.states), index >= 1 do
        assert {:ok, %Step{index: ^index} = step} = Step.from_state(state, index, [])
        step
      end

    assert Enum.map(steps, & &1.action_taken) == ["Reset", "Inc", "SetTo", "Reset"]

    assert Enum.map(steps, & &1.result) ==
             [{:rejected, "not_allowed"}, :accepted, :accepted, {:rejected, "not_allowed"}]

    assert Enum.at(steps, 1).nondet_picks == %{"by" => 1}
    assert Enum.at(steps, 2).nondet_picks == %{"value" => 5}

    assert Enum.at(steps, 1).state |> Map.keys() |> Enum.sort() ==
             ["lst", "m", "n", "rec", "s", "st", "tup"]
  end
end
