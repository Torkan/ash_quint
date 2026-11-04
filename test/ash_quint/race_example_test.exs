defmodule AshQuint.RaceExampleTest do
  # The race example end to end: every committed trace of
  # priv/examples/race replays concurrently against the Ash resource, with
  # the atomic :inc_atomic action. The read-modify-write :inc loses an
  # update in raceTest.
  use ExUnit.Case, async: true

  use AshQuint.Case,
    model: :race,
    adapter: AshQuint.Test.RaceAdapter

  alias AshQuint.{Config, Manifest, Replay, Step, Trace}
  alias AshQuint.Test.RaceAdapter

  @out "priv/examples/race/traces"

  defp manifest, do: Manifest.read!(Path.join(@out, "manifest.json"))

  defp load(file) do
    entry = Enum.find(manifest().traces, &(&1.file == file))

    Trace.load!(Path.join(@out, file),
      name: entry.name,
      source: entry.source,
      seed: manifest().seed
    )
  end

  defp model, do: Config.model!(Config.load!(), :race)

  defp replay(file, adapter_opts \\ []) do
    model = model()

    Replay.run(RaceAdapter, load(file),
      model: :race,
      pending_result: model.pending_result,
      op_field: model.op_field,
      adapter_opts: adapter_opts
    )
  end

  test "every race trace is concurrent, and raceTest has both ops in flight" do
    assert Enum.all?(manifest().traces, & &1.concurrent)

    assert %{max_in_flight: 2, actions: %{"IncStart" => 2, "IncDone" => 2}} =
             Enum.find(manifest().traces, &(&1.file == "scenario_raceTest.itf.json"))
  end

  test "the counter's manifest stays sequential" do
    counter = Manifest.read!("priv/examples/counter/traces/manifest.json")
    refute Enum.any?(counter.traces, & &1.concurrent)
    refute File.read!("priv/examples/counter/traces/manifest.json") =~ "concurrent"
  end

  test "raceTest decodes to Pending starts and completions with outcomes" do
    opts = [pending_result: model().pending_result, op_field: model().op_field]
    trace = load("scenario_raceTest.itf.json")

    steps =
      for {state, index} <- Enum.with_index(trace.states), index >= 1 do
        {:ok, step} = Step.from_state(state, index, opts)
        {step.action_taken, step.op, step.result}
      end

    assert steps == [
             {"IncStart", "o1", :pending},
             {"IncStart", "o2", :pending},
             {"IncDone", "o2", :accepted},
             {"IncDone", "o1", {:rejected, "over_limit"}}
           ]
  end

  test "raceTest against :inc fails at step 4 (IncDone) on the outcome and on writes" do
    assert {:error, failure} = replay("scenario_raceTest.itf.json", action: :inc)
    assert %{index: 4, action: "IncDone"} = failure

    assert failure.message ==
             "race scenario raceTest, step 4 (IncDone), seed 20261104: " <>
               "op \"o1\" (started at step 1): " <>
               "outcome: expected {:rejected, \"over_limit\"}, got :accepted\n" <>
               "key \"writes\":\n  expected: 1\n  actual:   2"
  end

  test "raceTest against :inc_atomic holds both ops at their gate until they complete" do
    assert {:ok, report} = replay("scenario_raceTest.itf.json")

    assert Enum.map(report.synced, &{&1.kind, &1.op, &1.expected}) == [
             {:start, "o1", %{"count" => 0, "writes" => 0}},
             {:start, "o2", %{"count" => 0, "writes" => 0}},
             {:complete, "o2", %{"count" => 2, "writes" => 1}},
             {:complete, "o1", %{"count" => 2, "writes" => 1}}
           ]
  end

  test "witness_witOverlap ends with both ops in flight and passes" do
    trace = load("witness_witOverlap.itf.json")
    opts = [pending_result: model().pending_result, op_field: model().op_field]
    {:ok, last} = Step.from_state(List.last(trace.states), length(trace.states) - 1, opts)
    assert last.result == :pending

    assert {:ok, report} = replay("witness_witOverlap.itf.json")
    assert List.last(report.synced).kind == :start

    assert {:ok, _report} = replay("witness_witOverlap.itf.json", action: :inc)
  end
end
