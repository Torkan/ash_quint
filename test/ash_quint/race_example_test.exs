defmodule AshQuint.RaceExampleTest do
  # The race example's committed traces (priv/examples/race) follow the
  # concurrency convention: starts are Pending and carry an op. Replaying
  # them needs concurrent replay, which isn't there yet, so a sequential
  # adapter is refused with a pointer to the start/complete API.
  use ExUnit.Case, async: true

  alias AshQuint.{Config, Manifest, Replay, Step, Trace}

  @out "priv/examples/race/traces"

  defmodule SequentialAdapter do
    @moduledoc false
    # Defers each IncStart and makes the call at its IncDone: the most a
    # sequential adapter can do.
    use AshQuint.Adapter

    @impl true
    def init(_trace, _opts), do: {:ok, %{count: 0, writes: 0, pending: nil}}

    @impl true
    def step(ctx, %Step{action_taken: "IncStart", nondet_picks: %{"by" => by}}),
      do: {:pending, %{ctx | pending: by}}

    def step(%{pending: by} = ctx, %Step{action_taken: "IncDone"}) do
      ctx = %{ctx | count: ctx.count + by, writes: ctx.writes + 1, pending: nil}
      {:ok, :ok, ctx}
    end

    @impl true
    def project(ctx), do: %{"count" => ctx.count, "writes" => ctx.writes}
  end

  defp manifest, do: Manifest.read!(Path.join(@out, "manifest.json"))

  defp load(entry) do
    Trace.load!(Path.join(@out, entry.file),
      name: entry.name,
      source: entry.source,
      seed: manifest().seed
    )
  end

  defp entry(file), do: Enum.find(manifest().traces, &(&1.file == file))

  test "every race trace is concurrent, and raceTest has both ops in flight" do
    assert Enum.all?(manifest().traces, & &1.concurrent)

    assert %{max_in_flight: 2, actions: %{"IncStart" => 2, "IncDone" => 2}} =
             entry("scenario_raceTest.itf.json")

    assert %{max_in_flight: 2} = entry("witness_witOverlap.itf.json")
  end

  test "the counter's manifest stays sequential" do
    counter = Manifest.read!("priv/examples/counter/traces/manifest.json")
    refute Enum.any?(counter.traces, & &1.concurrent)
    refute File.read!("priv/examples/counter/traces/manifest.json") =~ "concurrent"
  end

  test "raceTest decodes to Pending starts and completions with outcomes" do
    model = Config.model!(Config.load!(), :race)
    opts = [pending_result: model.pending_result, op_field: model.op_field]
    trace = load(entry("scenario_raceTest.itf.json"))

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

  test "a sequential replay refuses raceTest, naming the start/complete API" do
    trace = load(entry("scenario_raceTest.itf.json"))

    assert {:error, failure} = Replay.run(SequentialAdapter, trace, model: :race)
    assert %{index: 2, action: "IncStart"} = failure

    assert failure.message =~
             "race scenario raceTest, step 2 (IncStart), seed 20261104: interleaved trace: "

    assert failure.message =~ "{:start, op, call, ctx} and {:complete, op, ctx}"
  end
end
