defmodule AshQuint.Postgres.RacePgTest do
  # The race example over Postgres, unboxed: the committed race traces
  # replay concurrently against AshQuint.Test.PgRaceCounter (each op task on
  # a connection of its own) and pass the sensitivity check; the
  # read-modify-write :inc loses an update in raceTest.
  use AshQuint.Test.DataCase, unboxed: true

  use AshQuint.Case,
    model: :race,
    adapter: AshQuint.Test.RacePgAdapter,
    traces: :concurrent,
    sensitivity: [allow_untested: [vars: ~w(inflight finished)]]

  alias AshQuint.{Config, Manifest, Replay, Trace}
  alias AshQuint.Test.RacePgAdapter

  @out "priv/examples/race/traces"

  defp replay(file, adapter_opts) do
    model = Config.model!(Config.load!(), :race)
    manifest = Manifest.read!(Path.join(@out, "manifest.json"))
    entry = Enum.find(manifest.traces, &(&1.file == file))

    trace =
      Trace.load!(Path.join(@out, file),
        name: entry.name,
        source: entry.source,
        seed: manifest.seed
      )

    Replay.run(RacePgAdapter, trace,
      model: :race,
      pending_result: model.pending_result,
      op_field: model.op_field,
      adapter_opts: adapter_opts
    )
  end

  defp rows, do: TestRepo.query!("select count(*) from race_counters").rows

  test "raceTest against the read-modify-write action fails at step 4" do
    assert {:error, failure} = replay("scenario_raceTest.itf.json", action: :inc)
    assert %{index: 4, action: "IncDone"} = failure

    assert failure.message ==
             "race scenario raceTest, step 4 (IncDone), seed 20261104: " <>
               "op \"o1\" (started at step 1): " <>
               "outcome: expected {:rejected, \"over_limit\"}, got :accepted\n" <>
               "key \"writes\":\n  expected: 1\n  actual:   2"
  end

  test "finish/2 deletes the replay's row, pass or fail" do
    before = rows()
    assert {:ok, _report} = replay("scenario_raceTest.itf.json", [])
    assert {:error, _failure} = replay("scenario_raceTest.itf.json", action: :inc)
    assert rows() == before
  end
end
