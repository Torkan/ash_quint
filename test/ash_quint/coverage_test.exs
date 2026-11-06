defmodule AshQuint.CoverageTest do
  use ExUnit.Case, async: true

  alias AshQuint.Coverage
  alias AshQuint.Interface
  alias AshQuint.Manifest

  defp trace(file, steps, actions, outcomes) do
    %{
      file: file,
      source: :random,
      name: file,
      steps: steps,
      actions: actions,
      outcomes: outcomes
    }
  end

  # `actions` are the interface's (all unit); by default Init and the
  # actions the traces take.
  defp manifest(traces, actions \\ nil) do
    actions =
      actions ||
        ["Init" | traces |> Enum.flat_map(&Map.keys(&1.actions)) |> Enum.uniq()]

    interface = %Interface{
      actions: Enum.map(actions, &%{name: &1, picks: :unit, type: nil}),
      results: ["Accepted", "Rejected"],
      vars: []
    }

    %Manifest{quint: "0.33.1", seed: 1, traces: traces, interface: interface}
  end

  test "sums actions and outcomes over the traces, rows sorted by action" do
    manifest =
      manifest([
        trace("a", 3, %{"Inc" => 2, "Reset" => 1}, %{
          "Inc" => %{"accepted" => 1, "rejected:over_limit" => 1},
          "Reset" => %{"accepted" => 1}
        }),
        trace("b", 2, %{"Inc" => 2}, %{"Inc" => %{"accepted" => 2}})
      ])

    assert Coverage.from_manifest(manifest) ==
             {:ok,
              %{
                traces: 2,
                steps: 5,
                all_actions: true,
                rows: [
                  %{
                    action: "Inc",
                    steps: 4,
                    outcomes: %{"accepted" => 3, "rejected:over_limit" => 1},
                    no_result: 0
                  },
                  %{action: "Reset", steps: 1, outcomes: %{"accepted" => 1}, no_result: 0}
                ]
              }}
  end

  test "an action that both starts and completes ops shows pending next to outcomes" do
    {:ok, coverage} =
      Coverage.from_manifest(
        manifest([
          trace("a", 8, %{"Inc" => 8}, %{
            "Inc" => %{"pending" => 4, "accepted" => 3, "rejected:over_limit" => 1}
          })
        ])
      )

    assert Coverage.format("m", coverage) == [
             "m: 1 trace, 8 steps",
             "  Inc  8  accepted 3  pending 4  rejected:over_limit 1"
           ]
  end

  test "a version 1 manifest has no outcomes" do
    manifest = manifest([%{trace("a", 1, %{"Inc" => 1}, nil) | outcomes: nil}])
    assert Coverage.from_manifest(manifest) == {:error, :no_outcomes}
  end

  test "formats a table with aligned columns and labels sorted" do
    {:ok, coverage} =
      Coverage.from_manifest(
        manifest([
          trace("a", 12, %{"Inc" => 11, "Reset" => 1}, %{
            "Inc" => %{"rejected:over_limit" => 1, "accepted" => 10},
            "Reset" => %{"accepted" => 1}
          })
        ])
      )

    assert Coverage.format("counter", coverage) == [
             "counter: 1 trace, 12 steps",
             "  Inc    11  accepted 10  rejected:over_limit 1",
             "  Reset   1  accepted 1"
           ]
  end

  test "a model without results lists step counts only" do
    {:ok, coverage} =
      Coverage.from_manifest(manifest([trace("a", 3, %{"Inc" => 2, "Peek" => 1}, %{})]))

    assert Coverage.format("m", coverage) == ["m: 1 trace, 3 steps", "  Inc   2", "  Peek  1"]
  end

  test "steps without a result in a model with results show as no result" do
    {:ok, coverage} =
      Coverage.from_manifest(
        manifest([trace("a", 3, %{"Inc" => 2, "Peek" => 1}, %{"Inc" => %{"accepted" => 1}})])
      )

    assert Coverage.format("m", coverage) == [
             "m: 1 trace, 3 steps",
             "  Inc   2  accepted 1  no result 1",
             "  Peek  1  no result 1"
           ]
  end

  test "an action no trace takes has a zero row" do
    manifest =
      manifest(
        [trace("a", 10, %{"Inc" => 10}, %{"Inc" => %{"accepted" => 10}})],
        ["Init", "Undo", "Inc"]
      )

    assert {:ok, %{rows: rows, all_actions: true} = coverage} = Coverage.from_manifest(manifest)

    assert rows == [
             %{action: "Inc", steps: 10, outcomes: %{"accepted" => 10}, no_result: 0},
             %{action: "Undo", steps: 0, outcomes: %{}, no_result: 0}
           ]

    assert Coverage.format("m", coverage) == [
             "m: 1 trace, 10 steps",
             "  Inc   10  accepted 10",
             "  Undo   0"
           ]
  end

  test "the init action has no row" do
    traces = [trace("a", 1, %{"Inc" => 1}, %{"Inc" => %{"accepted" => 1}})]

    assert {:ok, %{rows: [%{action: "Inc"}]}} =
             Coverage.from_manifest(manifest(traces, ["Init", "Inc"]))

    assert {:ok, %{rows: [%{action: "Inc"}, %{action: "Init", steps: 0}]}} =
             Coverage.from_manifest(manifest(traces, ["Start", "Init", "Inc"]),
               init_action: "Start"
             )
  end

  test "a format 2 manifest ends with the regeneration note" do
    traces = [trace("a", 1, %{"Inc" => 1}, %{"Inc" => %{"accepted" => 1}})]
    manifest = %{manifest(traces, ["Init", "Inc", "Undo"]) | version: 2, interface: nil}

    assert {:ok, %{all_actions: false, rows: [%{action: "Inc"}]} = coverage} =
             Coverage.from_manifest(manifest)

    assert Coverage.format("counter", coverage) == [
             "counter: 1 trace, 1 step",
             "  Inc  1  accepted 1",
             "  (actions no trace takes aren't listed: regenerate with " <>
               "mix ash_quint.gen counter to record the model's actions)"
           ]
  end

  test "no traces" do
    {:ok, coverage} = Coverage.from_manifest(manifest([]))
    assert Coverage.format("m", coverage) == ["m: 0 traces, 0 steps"]
  end
end
