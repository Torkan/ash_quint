defmodule AshQuint.Postgres.RacePgTest do
  # The race example over Postgres, unboxed: the committed race traces
  # replay concurrently against AshQuint.Test.PgRaceCounter (each op task on
  # a connection of its own) and pass the sensitivity check; the
  # read-modify-write :inc loses an update in raceTest. An explore session
  # replays the same traces as fresh ones (no Quint: a fake runner copies
  # them).
  use AshQuint.Test.DataCase, unboxed: true

  use AshQuint.Case,
    model: :race,
    adapter: AshQuint.Test.RacePgAdapter,
    traces: :concurrent,
    sensitivity: [allow_untested: [vars: ~w(inflight finished)]]

  alias AshQuint.{Config, Explore, Manifest, Replay, Trace}
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

  @tag :tmp_dir
  test "an explore session replays the race traces through RacePgAdapter", %{tmp_dir: tmp_dir} do
    files = Path.wildcard(Path.join(@out, "*.itf.json")) |> Enum.sort()
    manifest = Manifest.read!(Path.join(@out, "manifest.json"))
    concurrent = Enum.count(manifest.traces, & &1.concurrent)

    runner = fn _exe, args, _opts ->
      "--out-itf=" <> out = Enum.find(args, &String.starts_with?(&1, "--out-itf="))

      files
      |> Enum.with_index()
      |> Enum.each(fn {file, i} ->
        File.cp!(file, String.replace(out, "{seq}", Integer.to_string(i)))
      end)

      {"", 0}
    end

    before = rows()

    report =
      Explore.run(
        %{runs: length(files), seed: 1, budget: nil, failures: 1},
        [model: :race, adapter: RacePgAdapter, traces: :concurrent, batch: length(files)],
        runner: runner,
        build_dir: Path.join(tmp_dir, "build"),
        tmp_dir: Path.join(tmp_dir, "tmp")
      )

    assert %{failures: [], error: nil, generated: generated} = report
    assert generated == length(files)
    assert report.replayed == concurrent
    assert report.skipped == length(files) - concurrent
    assert rows() == before
  end
end
