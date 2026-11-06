defmodule AshQuint.ExploreTest do
  # async: false: the run!/2 tests set ASH_QUINT_EXPLORE* env vars. The
  # "with Quint" tests run real Quint through npx: excluded by default, run
  # with `mix test --only quint_cli`.
  use ExUnit.Case, async: false

  alias AshQuint.{Config, Explore, Gen, ITF, Manifest, Replay, Trace}
  alias Config.Model
  alias Mix.Tasks.AshQuint.Promote

  alias AshQuint.Test.{
    ConcurrentToyAdapter,
    CounterAdapter,
    CounterAdapterOffByOne,
    RaceAdapter,
    ToyAdapter
  }

  @moduletag :tmp_dir

  @config "test/fixtures/case/ash_quint.exs"
  @ok_traces "test/fixtures/case/ok/*.itf.json"
  # Found by running the race explore test once; it finds the lost update.
  @race_seed 1
  # Found by running the off-by-one counter explore over seeds 1..40: its
  # candidate fails at step 5 and shrinks to one step.
  @counter_seed 9

  defmodule FlakyAdapter do
    @moduledoc false
    # The toy adapter, off by one only in the first replay that uses the
    # Agent in adapter_opts[:agent].
    use AshQuint.Adapter

    alias AshQuint.Test.ToyAdapter

    @impl true
    def init(trace, opts) do
      first = Agent.get_and_update(opts[:agent], &{&1, false})
      ToyAdapter.init(trace, faults: if(first, do: [:off_by_one], else: []))
    end

    @impl true
    defdelegate step(ctx, step), to: ToyAdapter

    @impl true
    defdelegate project(ctx), to: ToyAdapter

    @impl true
    defdelegate outcome(result), to: ToyAdapter
  end

  defmodule SpyAdapter do
    @moduledoc false
    # The toy adapter, telling adapter_opts[:test] about every replay:
    # {:replayed, whether the trace has a Pending step}.
    use AshQuint.Adapter

    alias AshQuint.Test.ToyAdapter

    @impl true
    def init(trace, opts) do
      pending? = Enum.any?(trace.states, &match?(%{"lastResult" => {:variant, "Pending", _}}, &1))
      send(opts[:test], {:replayed, pending?})
      ToyAdapter.init(trace, opts)
    end

    @impl true
    defdelegate step(ctx, step), to: ToyAdapter

    @impl true
    defdelegate project(ctx), to: ToyAdapter

    @impl true
    defdelegate outcome(result), to: ToyAdapter
  end

  # A runner that writes the fixture traces matching `glob`, cyclically, as
  # the batch's explore_<i>.itf.json files, sends its args to the test and
  # prints `output`.
  defp runner(glob \\ @ok_traces, output \\ "") do
    fixtures = glob |> Path.wildcard() |> Enum.sort()
    test = self()

    fn _exe, args, opts ->
      send(test, {:quint, args, opts})
      "--out-itf=" <> out = Enum.find(args, &String.starts_with?(&1, "--out-itf="))
      "--n-traces=" <> n = Enum.find(args, &String.starts_with?(&1, "--n-traces="))

      fixtures
      |> Stream.cycle()
      |> Enum.take(String.to_integer(n))
      |> Enum.with_index()
      |> Enum.each(fn {fixture, i} ->
        File.cp!(fixture, String.replace(out, "{seq}", Integer.to_string(i)))
      end)

      {output, 0}
    end
  end

  # A config in `tmp_dir` with the ok fixture model and `witnesses`.
  defp witness_config(tmp_dir, witnesses) do
    config = Path.join(tmp_dir, "ash_quint.exs")

    File.write!(config, """
    [
      quint: "0.33.1",
      models: [
        ok: [
          model: "test/fixtures/case/ok/model.qnt",
          out: "test/fixtures/case/ok",
          seed: 7,
          random: [main: "toy", max_steps: 3],
          witnesses: #{inspect(witnesses)}
        ]
      ]
    ]
    """)

    config
  end

  defp witnessed(tmp_dir),
    do: [config: witness_config(tmp_dir, main: "toy", names: ~w(witA witB))]

  defp settings(overrides \\ []) do
    Map.merge(%{runs: 5, seed: 10, budget: nil, failures: 1}, Map.new(overrides))
  end

  defp run(settings, opts, tmp_dir, run_opts \\ []) do
    opts = Keyword.merge([model: :ok, adapter: ToyAdapter, config: @config, batch: 2], opts)

    run_opts =
      Keyword.merge(
        [
          runner: runner(),
          build_dir: Path.join(tmp_dir, "build"),
          tmp_dir: Path.join(tmp_dir, "tmp")
        ],
        run_opts
      )

    Explore.run(settings, opts, run_opts)
  end

  defp quint_args do
    receive do
      {:quint, args, _opts} -> [args | quint_args()]
    after
      0 -> []
    end
  end

  defp flag(args, name) do
    Enum.find_value(args, fn arg ->
      case String.split(arg, "=", parts: 2) do
        ["--" <> ^name, value] -> value
        _other -> nil
      end
    end)
  end

  describe "settings!/1" do
    test "settings!/1 defaults" do
      assert %{runs: 100, budget: nil, failures: 1, seed: seed} = Explore.settings!(%{})
      assert seed in 1..4_294_967_295
    end

    test "settings!/1 reads the variables" do
      env = %{
        "ASH_QUINT_EXPLORE_RUNS" => "500",
        "ASH_QUINT_EXPLORE_SEED" => "7",
        "ASH_QUINT_EXPLORE_BUDGET" => "60",
        "ASH_QUINT_EXPLORE_FAILURES" => "3"
      }

      assert Explore.settings!(env) == %{runs: 500, seed: 7, budget: 60, failures: 3}
    end

    test "settings!/1 names a malformed variable" do
      for {name, value} <- [
            {"ASH_QUINT_EXPLORE_RUNS", "abc"},
            {"ASH_QUINT_EXPLORE_RUNS", "0"},
            {"ASH_QUINT_EXPLORE_SEED", "-1"},
            {"ASH_QUINT_EXPLORE_BUDGET", "1.5"},
            {"ASH_QUINT_EXPLORE_FAILURES", ""}
          ] do
        error = assert_raise ArgumentError, fn -> Explore.settings!(%{name => value}) end
        assert error.message == "#{name} must be a positive integer, got #{inspect(value)}"
      end
    end
  end

  describe "run/3" do
    test "a passing session runs batches with consecutive seeds", %{tmp_dir: tmp_dir} do
      report = run(settings(), [], tmp_dir)

      args = quint_args()
      assert Enum.map(args, &flag(&1, "seed")) == ["10", "11", "12"]
      assert Enum.map(args, &flag(&1, "n-traces")) == ["2", "2", "1"]
      assert Enum.map(args, &flag(&1, "max-samples")) == ["2", "2", "1"]
      assert Enum.map(args, &flag(&1, "max-steps")) == ["3", "3", "3"]

      assert report == %{
               generated: 5,
               replayed: 5,
               skipped: 0,
               seeds: 10..12,
               failures: [],
               error: nil,
               witnesses: []
             }
    end

    test "witness rates are parsed and summed over batches", %{tmp_dir: tmp_dir} do
      output = """
      [ok] No violation found (10ms at 300 traces/second).
      Witnesses:
      witA was witnessed in 1 trace(s) out of 2 explored (50.00%)
      witB was witnessed in 0 trace(s) out of 2 explored (0.00%)
      """

      report =
        run(settings(runs: 4), witnessed(tmp_dir), tmp_dir, runner: runner(@ok_traces, output))

      assert report.witnesses == [
               %{name: "witA", hits: 2, traces: 4},
               %{name: "witB", hits: 0, traces: 4}
             ]
    end

    test "--witnesses comes last with every name", %{tmp_dir: tmp_dir} do
      run(settings(runs: 4), witnessed(tmp_dir), tmp_dir)

      for args <- quint_args() do
        assert Enum.take(args, -3) == ["--witnesses", "witA", "witB"]
      end
    end

    test "no --witnesses when the witness main differs", %{tmp_dir: tmp_dir} do
      report =
        run(
          settings(runs: 2),
          [config: witness_config(tmp_dir, main: "other", names: ~w(witA witB))],
          tmp_dir
        )

      assert [args] = quint_args()
      refute "--witnesses" in args
      assert report.witnesses == []
    end

    test "no --witnesses without witnesses", %{tmp_dir: tmp_dir} do
      report = run(settings(runs: 2), [], tmp_dir)

      assert [args] = quint_args()
      refute "--witnesses" in args
      assert report.witnesses == []
    end

    test "missing counts make the rates unknown", %{tmp_dir: tmp_dir} do
      output = "witA was witnessed in 1 trace(s) out of 2 explored (50.00%)\n"

      report =
        run(settings(runs: 4), witnessed(tmp_dir), tmp_dir, runner: runner(@ok_traces, output))

      assert report.witnesses == :unknown
      assert %{generated: 4, replayed: 4, failures: [], error: nil} = report
    end

    test "a batch missing a count keeps the rates unknown", %{tmp_dir: tmp_dir} do
      # The first batch lacks witB's line, the second has both.
      full = """
      witA was witnessed in 1 trace(s) out of 2 explored (50.00%)
      witB was witnessed in 2 trace(s) out of 2 explored (100.00%)
      """

      partial = "witA was witnessed in 1 trace(s) out of 2 explored (50.00%)\n"
      {:ok, outputs} = Agent.start_link(fn -> [partial, full] end)
      write = runner()

      runner = fn exe, args, opts ->
        write.(exe, args, opts)
        {Agent.get_and_update(outputs, fn [output | rest] -> {output, rest} end), 0}
      end

      report = run(settings(runs: 4), witnessed(tmp_dir), tmp_dir, runner: runner)
      assert report.witnesses == :unknown
    end

    test "max_steps: overrides the model's", %{tmp_dir: tmp_dir} do
      run(settings(runs: 1), [max_steps: 7], tmp_dir)
      assert [args] = quint_args()
      assert flag(args, "max-steps") == "7"
    end

    test "Quint runs in the project root with the configured command", %{tmp_dir: tmp_dir} do
      run(settings(runs: 1), [], tmp_dir)
      assert_received {:quint, ["--yes", "@informalsystems/quint@0.33.1" | args], opts}
      assert opts == [cd: File.cwd!()]

      assert ["run", "test/fixtures/case/ok/model.qnt", "--main=toy", "--seed=10" | _rest] =
               args
    end

    test "a failure is cut, confirmed and written", %{tmp_dir: tmp_dir} do
      report = run(settings(), [adapter_opts: [faults: [:off_by_one]]], tmp_dir)

      assert [failure] = report.failures
      assert %{seed: 10, index: 0, cut_at: 1, reproduced: true} = failure
      assert failure.message =~ ~r/\Aok regression 10_0, step 1 \(Inc\), seed 10: /

      candidate = Path.join(tmp_dir, "build/ash_quint/explore/ok/regression_10_0.itf.json")
      assert failure.candidate == candidate

      binary = File.read!(candidate)
      assert length(Jason.decode!(binary)["states"]) == 2
      assert [args] = quint_args()

      assert Gen.provenance(binary) ==
               {:ok,
                %{
                  "model" => "ok",
                  "seed" => 10,
                  "index" => 0,
                  "steps" => 3,
                  "cut_at" => 1,
                  "quint" => "0.33.1",
                  "model_hash" => Manifest.hash_file("test/fixtures/case/ok/model.qnt"),
                  # Without --out-itf: its temp path means nothing once committed.
                  "args" =>
                    Enum.reject(
                      args -- ["--yes", "@informalsystems/quint@0.33.1"],
                      &String.starts_with?(&1, "--out-itf=")
                    )
                }}

      refute Enum.any?(
               elem(Gen.provenance(binary), 1)["args"],
               &String.starts_with?(&1, "--out")
             )

      # The failure cap (1) stopped the session after the first batch.
      assert %{generated: 2, replayed: 1, seeds: 10..10, error: nil} = report
    end

    test "batches pass the model's backend and record it in the provenance args", %{
      tmp_dir: tmp_dir
    } do
      # The ok fixture model, with a backend.
      config = Path.join(tmp_dir, "ash_quint.exs")

      File.write!(config, """
      [
        quint: "0.33.1",
        models: [
          ok: [
            model: "test/fixtures/case/ok/model.qnt",
            out: "test/fixtures/case/ok",
            seed: 7,
            backend: "rust",
            random: [main: "toy", max_steps: 3]
          ]
        ]
      ]
      """)

      report = run(settings(), [config: config, adapter_opts: [faults: [:off_by_one]]], tmp_dir)

      assert [args] = quint_args()
      assert "--backend=rust" in args
      assert [%{candidate: candidate}] = report.failures
      assert {:ok, %{"args" => recorded}} = Gen.provenance(File.read!(candidate))
      assert "--backend=rust" in recorded
    end

    test "a failure block prints the quint command", %{tmp_dir: tmp_dir} do
      report = run(settings(), [adapter_opts: [faults: [:off_by_one]]], tmp_dir)

      assert [failure] = report.failures

      assert failure.quint ==
               "npx --yes @informalsystems/quint@0.33.1 run test/fixtures/case/ok/model.qnt " <>
                 "--main=toy --seed=10 --max-steps=3 --max-samples=2 --n-traces=2 " <>
                 "'--out-itf=explore_{seq}.itf.json' (trace 0)"

      path = Path.relative_to_cwd(failure.candidate)

      assert [_header, block] = String.split(Explore.format(:ok, report), "\n\n")

      assert Enum.take(String.split(block, "\n"), -3) == [
               "candidate: #{path} (cut to 1 steps)",
               "quint:     " <> failure.quint,
               "promote:   MIX_ENV=test mix ash_quint.promote #{path}"
             ]

      assert block ==
               "#{failure.message}\ncandidate: #{path} (cut to 1 steps)\n" <>
                 "quint:     #{failure.quint}\npromote:   MIX_ENV=test mix ash_quint.promote #{path}"
    end

    test "an explore failure's message has no context lines", %{tmp_dir: tmp_dir} do
      report = run(settings(), [adapter_opts: [faults: [:off_by_one]]], tmp_dir)

      assert [failure] = report.failures

      assert List.last(String.split(failure.message, "\n")) ==
               ~s(model step: Inc %{"by" => 1}, result :accepted)
    end

    test "a failure at the last step isn't cut", %{tmp_dir: tmp_dir} do
      runner = runner("test/fixtures/case/ok/scenario_incTest.itf.json")

      report =
        run(settings(), [adapter_opts: [faults: [:off_by_one]]], tmp_dir, runner: runner)

      assert [%{cut_at: nil, reproduced: true, candidate: candidate}] = report.failures
      assert length(Jason.decode!(File.read!(candidate))["states"]) == 2
      assert {:ok, %{"cut_at" => nil, "steps" => 1}} = Gen.provenance(File.read!(candidate))
    end

    test "a failure that doesn't reproduce keeps the full trace", %{tmp_dir: tmp_dir} do
      {:ok, agent} = Agent.start_link(fn -> true end)

      report =
        run(settings(), [adapter: FlakyAdapter, adapter_opts: [agent: agent]], tmp_dir)

      assert [%{cut_at: nil, reproduced: false, candidate: candidate}] = report.failures
      assert length(Jason.decode!(File.read!(candidate))["states"]) == 4
      assert {:ok, %{"cut_at" => nil, "steps" => 3}} = Gen.provenance(File.read!(candidate))
    end

    test "an adapter exception is a failure, not cut", %{tmp_dir: tmp_dir} do
      report = run(settings(), [adapter_opts: [faults: [:raise]]], tmp_dir)

      assert [%{cut_at: nil, reproduced: nil, candidate: candidate} = failure] =
               report.failures

      assert failure.message == "ok regression 10_0: ** (RuntimeError) db down"
      assert length(Jason.decode!(File.read!(candidate))["states"]) == 4
    end

    test "failures: N stops after N failures", %{tmp_dir: tmp_dir} do
      report =
        run(
          settings(runs: 10, failures: 2),
          [adapter_opts: [faults: [:off_by_one]]],
          tmp_dir
        )

      assert [%{index: 0}, %{index: 1}] = report.failures
      assert %{generated: 2, replayed: 2} = report
    end

    test "the budget stops new batches", %{tmp_dir: tmp_dir} do
      {:ok, clock} = Agent.start_link(fn -> [0, 5000] end)
      now = fn -> Agent.get_and_update(clock, fn [t | rest] -> {t, rest ++ [t]} end) end

      report = run(settings(runs: 10, budget: 1), [], tmp_dir, now: now)

      assert %{generated: 2, replayed: 2, seeds: 10..10} = report
      assert [_one_batch] = quint_args()
    end

    test "traces: selects sequential or concurrent fresh traces", %{tmp_dir: tmp_dir} do
      # concurrent/: random_0 is sequential, scenario_overlapTest concurrent;
      # three traces cycle through them as random_0, overlapTest, random_0.
      runner = runner("test/fixtures/case/concurrent/*.itf.json")

      for {traces, replayed, skipped} <- [
            {:sequential, 2, 1},
            {:concurrent, 1, 2},
            {:all, 3, 0}
          ] do
        report =
          run(
            settings(runs: 3),
            [adapter: ConcurrentToyAdapter, traces: traces, batch: 3],
            tmp_dir,
            runner: runner
          )

        assert %{generated: 3, replayed: ^replayed, skipped: ^skipped, failures: []} = report
      end
    end

    test "Quint failing ends the session with its output", %{tmp_dir: tmp_dir} do
      {:ok, calls} = Agent.start_link(fn -> 0 end)
      ok = runner()

      runner = fn exe, args, opts ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 -> ok.(exe, args, opts)
          _later -> {"boom", 1}
        end
      end

      report =
        run(settings(failures: 10), [adapter_opts: [faults: [:raise]]], tmp_dir, runner: runner)

      assert report.error == "quint run for :ok explore failed:\nboom"
      assert %{generated: 2, seeds: 10..11} = report
      assert [_, _] = report.failures
    end

    test "a missing executable is reported as gen does", %{tmp_dir: tmp_dir} do
      runner = fn _exe, _args, _opts -> :erlang.error(:enoent) end
      report = run(settings(), [], tmp_dir, runner: runner)

      assert report.error ==
               "could not run Quint (npx --yes @informalsystems/quint@0.33.1): " <>
                 "executable not found"

      assert %{generated: 0, replayed: 0, failures: []} = report
    end

    test "a fresh trace that doesn't decode ends the session", %{tmp_dir: tmp_dir} do
      {:ok, calls} = Agent.start_link(fn -> 0 end)
      ok = runner()

      # The first batch is the fixtures; the second's trace 1 isn't ITF.
      runner = fn exe, args, opts ->
        result = ok.(exe, args, opts)

        if Agent.get_and_update(calls, &{&1, &1 + 1}) == 1 do
          "--out-itf=" <> out = Enum.find(args, &String.starts_with?(&1, "--out-itf="))
          File.write!(String.replace(out, "{seq}", "1"), ~s({"states": 1}))
        end

        result
      end

      report =
        run(settings(failures: 10), [adapter_opts: [faults: [:raise]]], tmp_dir, runner: runner)

      assert report.error ==
               "fresh trace 11_1 of :ok could not be read: " <>
                 "explore 11_1 at $: not an ITF trace (needs vars and states lists)"

      assert %{generated: 4, replayed: 3, seeds: 10..11} = report
      assert [%{index: 0}, %{index: 1}, %{index: 0}] = report.failures
      assert File.ls!(Path.join(tmp_dir, "tmp")) == []
    end

    test "a fresh trace that isn't JSON ends the session", %{tmp_dir: tmp_dir} do
      ok = runner()

      runner = fn exe, args, opts ->
        result = ok.(exe, args, opts)
        "--out-itf=" <> out = Enum.find(args, &String.starts_with?(&1, "--out-itf="))
        File.write!(String.replace(out, "{seq}", "0"), "{")
        result
      end

      report = run(settings(), [], tmp_dir, runner: runner)

      assert report.error =~ ~r/\Afresh trace 10_0 of :ok could not be read: .+/
      assert %{generated: 2, replayed: 0, failures: []} = report
      assert File.ls!(Path.join(tmp_dir, "tmp")) == []
    end

    test "a fresh trace the selection can't read ends the session", %{tmp_dir: tmp_dir} do
      ok = runner()

      runner = fn exe, args, opts ->
        result = ok.(exe, args, opts)
        "--out-itf=" <> out = Enum.find(args, &String.starts_with?(&1, "--out-itf="))
        trace = %{"vars" => ["n"], "states" => [%{"n" => 0}, %{"n" => 1}]}
        File.write!(String.replace(out, "{seq}", "0"), Jason.encode!(trace))
        result
      end

      report = run(settings(), [traces: :sequential], tmp_dir, runner: runner)

      assert report.error ==
               "fresh trace 10_0 of :ok could not be read: " <>
                 "regression_10_0.itf.json, state 1: no action at lastAction"

      assert %{generated: 2, replayed: 0, skipped: 0, failures: []} = report
    end

    test "removes each batch's temp dir", %{tmp_dir: tmp_dir} do
      run(settings(), [], tmp_dir)
      assert File.ls!(Path.join(tmp_dir, "tmp")) == []
    end
  end

  describe "shrinking" do
    @shrink_batch "test/fixtures/case/shrink/batch/explore.itf.json"

    # A runner that serves `quint run` batches like runner/2, and `quint
    # test` by evaluating each run of the wrapper on the toy counter
    # (`reset` sets 0, `inc(n)` adds n), writing its ITF as Quint would.
    defp shrink_runner(glob \\ @shrink_batch) do
      batch = runner(glob)

      fn exe, args, opts ->
        if "test" in args, do: toy_quint_test(args), else: batch.(exe, args, opts)
      end
    end

    defp toy_quint_test(args) do
      send(self(), {:quint_test, args})
      wrapper = Enum.at(args, Enum.find_index(args, &(&1 == "test")) + 1)
      "--out-itf=" <> out = Enum.find(args, &String.starts_with?(&1, "--out-itf="))
      runs = Regex.scan(~r/^  run (shrink_\d+) = (.*)$/m, File.read!(wrapper))

      for [_line, name, run] <- runs do
        calls = Regex.scan(~r/\.then\(([a-z]+(?:\(\d+\))?)\)/, run, capture: :all_but_first)
        init = toy_state(0, "Init", %{"#tup" => []})
        states = Enum.scan(List.flatten(calls), init, &toy_step/2)

        itf = %{
          "#meta" => %{"format" => "ITF", "status" => "ok"},
          "vars" => ~w(count lastAction lastResult),
          "states" => [init | states]
        }

        File.write!(String.replace(out, "{test}", name), Jason.encode!(itf))
      end

      {"", 0}
    end

    defp toy_step("reset", _state), do: toy_state(0, "Reset", %{"#tup" => []})

    defp toy_step("inc(" <> by, %{"count" => %{"#bigint" => count}}) do
      by = by |> String.trim_trailing(")") |> String.to_integer()
      toy_state(String.to_integer(count) + by, "Inc", %{"by" => %{"#bigint" => "#{by}"}})
    end

    defp toy_state(count, tag, value) do
      %{
        "count" => %{"#bigint" => "#{count}"},
        "lastAction" => %{"tag" => tag, "value" => value},
        "lastResult" => %{"tag" => "Accepted", "value" => %{"#tup" => []}}
      }
    end

    # The values of every {tag, value} message received so far.
    defp drain(tag) do
      receive do
        {^tag, value} -> [value | drain(tag)]
      after
        0 -> []
      end
    end

    defp pending_reset(states) do
      case Enum.find_index(states, &match?(%{"lastAction" => %{"tag" => "Reset"}}, &1)) do
        nil ->
          states

        i ->
          List.update_at(states, i, fn state ->
            %{
              state
              | "lastAction" => %{"tag" => "Reset", "value" => %{"op" => "o1"}},
                "lastResult" => %{"tag" => "Pending", "value" => %{"#tup" => []}}
            }
          end)
      end
    end

    defp quint_tests do
      receive do
        {:quint_test, args} -> [args | quint_tests()]
      after
        0 -> []
      end
    end

    defp block_lines(report) do
      assert [_header, block] = String.split(Explore.format(:shrink, report), "\n\n")
      String.split(block, "\n")
    end

    @off_by_one [model: :shrink, adapter_opts: [faults: [:off_by_one]]]

    test "without shrink: the runner never runs quint test", %{tmp_dir: tmp_dir} do
      report = run(settings(), [adapter_opts: [faults: [:off_by_one]]], tmp_dir)

      assert [%{shrunk: nil}] = report.failures
      assert Enum.all?(quint_args(), &("run" in &1 and "test" not in &1))
    end

    test "a shrunk candidate is written with its provenance", %{tmp_dir: tmp_dir} do
      report = run(settings(), @off_by_one, tmp_dir, runner: shrink_runner())

      assert [failure] = report.failures
      assert %{cut_at: nil, reproduced: true} = failure

      assert failure.shrunk == %{
               from: 3,
               steps: 1,
               rounds: 2,
               run: "init.then(inc(1))",
               stopped: nil
             }

      # The message is the shrunk trace's, as its promoted test prints it.
      assert failure.message =~ ~r/\Ashrink regression 10_0, step 1 \(Inc\), seed 10: /

      binary = File.read!(failure.candidate)

      assert %{"count" => %{"#bigint" => "1"}, "lastAction" => %{"tag" => "Inc"}} =
               List.last(Jason.decode!(binary)["states"])

      assert length(Jason.decode!(binary)["states"]) == 2
      assert Jason.decode!(binary)["#meta"]["source"] == "test/fixtures/case/shrink/model.qnt"

      assert {:ok, provenance} = Gen.provenance(binary)

      assert %{
               "shrunk" => %{"rounds" => 2, "run" => "init.then(inc(1))", "steps" => 1},
               "steps" => 3,
               "cut_at" => nil,
               "seed" => 10,
               "index" => 0
             } = provenance

      assert [batch_args] = quint_args() |> Enum.reject(&("test" in &1))

      assert provenance["args"] ==
               Enum.reject(
                 batch_args -- ["--yes", "@informalsystems/quint@0.33.1"],
                 &String.starts_with?(&1, "--out-itf=")
               )

      # Round 0 and two rounds, each one quint test; the work dir is gone.
      assert [_round0, _round1, _round2] = quint_tests()
      assert File.ls!(Path.join(tmp_dir, "build/ash_quint/shrink")) == []

      path = Path.relative_to_cwd(failure.candidate)

      assert Enum.drop(block_lines(report), length(String.split(failure.message, "\n"))) == [
               "candidate: #{path} (not cut)",
               "shrunk from 3 to 1 steps (2 rounds)",
               "quint:     " <> failure.quint,
               "run:       init.then(inc(1))",
               "promote:   MIX_ENV=test mix ash_quint.promote #{path}"
             ]
    end

    test "with a traces: selection, reductions in it are kept", %{tmp_dir: tmp_dir} do
      report =
        run(settings(), [traces: :sequential] ++ @off_by_one, tmp_dir, runner: shrink_runner())

      assert [%{shrunk: %{steps: 1, rounds: 2}}] = report.failures
    end

    test "with a traces: selection, a reduction that leaves it isn't kept", %{tmp_dir: tmp_dir} do
      batch = shrink_runner()

      # Round 0 as Quint writes it; in every later run the first Reset is a
      # pending op that never completes, so the reduction is concurrent.
      runner = fn exe, args, opts ->
        result = batch.(exe, args, opts)

        if "test" in args and Process.put(:round_zero_done, true) do
          "--out-itf=" <> out = Enum.find(args, &String.starts_with?(&1, "--out-itf="))

          for path <- Path.wildcard(String.replace(out, "{test}", "*")) do
            itf = Jason.decode!(File.read!(path))
            File.write!(path, Jason.encode!(%{itf | "states" => pending_reset(itf["states"])}))
            send(self(), {:reduction, File.read!(path)})
          end
        end

        result
      end

      opts = [
        traces: :sequential,
        model: :shrink,
        adapter: SpyAdapter,
        adapter_opts: [faults: [:off_by_one], test: self()]
      ]

      report = run(settings(), opts, tmp_dir, runner: runner)

      assert [%{shrunk: {:not_shrunk, "no step could be removed"}}] = report.failures

      # The reductions decode, are concurrent, and are never replayed.
      model = Config.model!(Config.load!(@config), :shrink)
      assert [_ | _] = reductions = drain(:reduction)

      for binary <- reductions do
        trace = ITF.decode!(Jason.decode!(binary), "reduction")
        assert Gen.entry("r.itf.json", :regression, "r", trace, model).concurrent
      end

      replayed = drain(:replayed)
      assert false in replayed
      refute true in replayed
    end

    test "a reduction Quint passes but that can't be decoded isn't kept", %{tmp_dir: tmp_dir} do
      batch = shrink_runner()

      # Round 0 as Quint writes it; every later run passes with a state the
      # ITF decoder refuses.
      runner = fn exe, args, opts ->
        result = batch.(exe, args, opts)

        if "test" in args and Process.put(:round_zero_done, true) do
          "--out-itf=" <> out = Enum.find(args, &String.starts_with?(&1, "--out-itf="))

          for path <- Path.wildcard(String.replace(out, "{test}", "*")) do
            itf = Jason.decode!(File.read!(path))
            states = List.update_at(itf["states"], -1, &Map.put(&1, "count", %{"#odd" => 1}))
            File.write!(path, Jason.encode!(%{itf | "states" => states}))
          end
        end

        result
      end

      report = run(settings(), @off_by_one, tmp_dir, runner: runner)

      assert [%{shrunk: {:not_shrunk, "no step could be removed"}}] = report.failures
    end

    test "a not shrunk candidate says why", %{tmp_dir: tmp_dir} do
      batch = runner(@shrink_batch)

      runner = fn exe, args, opts ->
        if "test" in args, do: {"error: boom\nmore\n", 1}, else: batch.(exe, args, opts)
      end

      report = run(settings(), @off_by_one, tmp_dir, runner: runner)

      assert [failure] = report.failures
      assert failure.shrunk == {:not_shrunk, "quint test failed: error: boom"}
      assert failure.message =~ ~r/\Ashrink regression 10_0, step 3 \(Inc\), seed 10: /

      binary = File.read!(failure.candidate)
      assert length(Jason.decode!(binary)["states"]) == 4
      assert {:ok, provenance} = Gen.provenance(binary)
      refute Map.has_key?(provenance, "shrunk")

      path = Path.relative_to_cwd(failure.candidate)

      assert Enum.drop(block_lines(report), length(String.split(failure.message, "\n"))) == [
               "candidate: #{path} (not cut)",
               "not shrunk: quint test failed: error: boom",
               "quint:     " <> failure.quint,
               "promote:   MIX_ENV=test mix ash_quint.promote #{path}"
             ]
    end

    test "a round that writes no runs stops shrinking, with a note", %{tmp_dir: tmp_dir} do
      inner = shrink_runner()

      # Round 0 and round 1 as Quint writes them; round 2 writes nothing.
      runner = fn exe, args, opts ->
        if "test" in args do
          calls = Process.get(:quint_test_calls, 0)
          Process.put(:quint_test_calls, calls + 1)
          if calls < 2, do: inner.(exe, args, opts), else: {"\nerror: gone\n", 1}
        else
          inner.(exe, args, opts)
        end
      end

      report = run(settings(), @off_by_one, tmp_dir, runner: runner)

      assert [failure] = report.failures

      assert %{steps: 2, rounds: 1, stopped: "quint test wrote no runs: error: gone"} =
               failure.shrunk

      path = Path.relative_to_cwd(failure.candidate)

      assert Enum.drop(block_lines(report), length(String.split(failure.message, "\n"))) == [
               "candidate: #{path} (not cut)",
               "shrunk from 3 to 2 steps (1 rounds)",
               "stopped:   quint test wrote no runs: error: gone",
               "quint:     " <> failure.quint,
               "run:       " <> failure.shrunk.run,
               "promote:   MIX_ENV=test mix ash_quint.promote #{path}"
             ]
    end

    test "shrinking that raises leaves the candidate unshrunk", %{tmp_dir: tmp_dir} do
      batch = runner(@shrink_batch)

      runner = fn exe, args, opts ->
        if "test" in args, do: raise("quint blew up"), else: batch.(exe, args, opts)
      end

      report = run(settings(), @off_by_one, tmp_dir, runner: runner)

      assert [failure] = report.failures
      assert failure.shrunk == {:not_shrunk, "shrinking raised: quint blew up"}

      binary = File.read!(failure.candidate)
      assert length(Jason.decode!(binary)["states"]) == 4
      assert {:ok, provenance} = Gen.provenance(binary)
      refute Map.has_key?(provenance, "shrunk")
      assert "not shrunk: shrinking raised: quint blew up" in block_lines(report)
    end

    test "no interface: not shrunk", %{tmp_dir: tmp_dir} do
      # The ok fixture model, whose manifest is format 1, with shrink: on.
      config = Path.join(tmp_dir, "ash_quint.exs")

      File.write!(config, """
      [
        quint: "0.33.1",
        models: [
          ok: [
            model: "test/fixtures/case/ok/model.qnt",
            out: "test/fixtures/case/ok",
            seed: 7,
            random: [main: "toy", max_steps: 3],
            shrink: true
          ]
        ]
      ]
      """)

      loaded = Config.load!(config)

      {:error, message} =
        Manifest.load(loaded, Config.model!(loaded, :ok), need: :interface)

      report =
        run(settings(), [config: config, adapter_opts: [faults: [:off_by_one]]], tmp_dir,
          runner: shrink_runner(@ok_traces)
        )

      assert [failure] = report.failures
      assert failure.shrunk == {:not_shrunk, message}
      assert ("not shrunk: " <> message) in String.split(Explore.format(:ok, report), "\n")
      assert quint_tests() == []
    end

    test "a candidate that didn't reproduce isn't shrunk", %{tmp_dir: tmp_dir} do
      {:ok, agent} = Agent.start_link(fn -> true end)

      report =
        run(
          settings(),
          [model: :shrink, adapter: FlakyAdapter, adapter_opts: [agent: agent]],
          tmp_dir,
          runner: shrink_runner()
        )

      assert [%{reproduced: false, shrunk: nil}] = report.failures
      assert quint_tests() == []
    end

    test "an adapter exception isn't shrunk", %{tmp_dir: tmp_dir} do
      report =
        run(
          settings(),
          [model: :shrink, adapter_opts: [faults: [:raise]]],
          tmp_dir,
          runner: shrink_runner()
        )

      assert [%{reproduced: nil, shrunk: nil}] = report.failures
      assert quint_tests() == []
    end
  end

  describe "run!/2" do
    @env ~w(ASH_QUINT_EXPLORE ASH_QUINT_EXPLORE_RUNS ASH_QUINT_EXPLORE_SEED
            ASH_QUINT_EXPLORE_BUDGET ASH_QUINT_EXPLORE_FAILURES)

    # Sets the explore variables to `env` (unset when missing) and restores
    # them afterwards.
    defp with_env(env, fun) do
      previous = Map.new(@env, &{&1, System.get_env(&1)})
      Enum.each(@env, &put_env(&1, env[&1]))

      try do
        fun.()
      after
        Enum.each(previous, fn {name, value} -> put_env(name, value) end)
      end
    end

    defp put_env(name, nil), do: System.delete_env(name)
    defp put_env(name, value), do: System.put_env(name, value)

    @explore_env %{
      "ASH_QUINT_EXPLORE" => "1",
      "ASH_QUINT_EXPLORE_RUNS" => "2",
      "ASH_QUINT_EXPLORE_SEED" => "10"
    }

    defp run!(opts, tmp_dir) do
      opts = Keyword.merge([model: :ok, adapter: ToyAdapter, config: @config], opts)

      Explore.run!(opts,
        runner: runner(),
        build_dir: Path.join(tmp_dir, "build"),
        tmp_dir: Path.join(tmp_dir, "tmp")
      )
    end

    test "the explore test flunks without ASH_QUINT_EXPLORE=1" do
      mod = Module.concat(__MODULE__, "Gen#{System.unique_integer([:positive])}")

      Code.compile_string("""
      defmodule #{inspect(mod)} do
        use ExUnit.Case, register: false

        use AshQuint.Case,
          config: #{inspect(@config)},
          model: :ok,
          adapter: AshQuint.Test.ToyAdapter,
          explore: true
      end
      """)

      test_name = :"test explore ok"

      for env <- [%{}, %{"ASH_QUINT_EXPLORE" => "true"}] do
        error =
          assert_raise ExUnit.AssertionError, fn ->
            with_env(env, fn -> apply(mod, test_name, [%{}]) end)
          end

        assert error.message ==
                 "explore test for :ok ran without mix ash_quint.explore; " <>
                   "add :quint_explore to ExUnit.start(exclude: …) in test/test_helper.exs"
      end
    end

    test "run!/2 prints the summary line", %{tmp_dir: tmp_dir} do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert with_env(@explore_env, fn -> run!([], tmp_dir) end) == :ok
        end)

      assert output == "explore ok: 2 traces (seeds 10..10), 0 failures, 0 skipped\n"
    end

    test "run!/2 flunks with the report", %{tmp_dir: tmp_dir} do
      opts = [adapter_opts: [faults: [:off_by_one]]]

      error =
        assert_raise ExUnit.AssertionError, fn ->
          ExUnit.CaptureIO.capture_io(fn ->
            with_env(@explore_env, fn -> run!(opts, tmp_dir) end)
          end)
        end

      report = run(settings(runs: 2), Keyword.put(opts, :batch, 20), tmp_dir)
      assert [_failure] = report.failures
      assert error.message == Explore.format(:ok, report)
    end

    test "run!/2 flunks when Quint fails", %{tmp_dir: tmp_dir} do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          ExUnit.CaptureIO.capture_io(fn ->
            with_env(@explore_env, fn ->
              Explore.run!([model: :ok, adapter: ToyAdapter, config: @config],
                runner: fn _exe, _args, _opts -> {"boom", 1} end,
                tmp_dir: Path.join(tmp_dir, "tmp")
              )
            end)
          end)
        end

      assert error.message ==
               "explore ok: 0 traces (seeds 10..10), 0 failures, 0 skipped\n\n" <>
                 "quint run for :ok explore failed:\nboom"
    end

    test "run!/2 flunks naming a malformed variable", %{tmp_dir: tmp_dir} do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          with_env(Map.put(@explore_env, "ASH_QUINT_EXPLORE_FAILURES", "x"), fn ->
            run!([], tmp_dir)
          end)
        end

      assert error.message == ~s(ASH_QUINT_EXPLORE_FAILURES must be a positive integer, got "x")
      refute_received {:quint, _args, _opts}
    end
  end

  describe "format/2" do
    test "a passing report" do
      report = %{
        generated: 100,
        replayed: 98,
        skipped: 2,
        seeds: 4031..4035,
        failures: [],
        error: nil,
        witnesses: []
      }

      assert Explore.format(:counter, report) ==
               "explore counter: 100 traces (seeds 4031..4035), 0 failures, 2 skipped"

      assert Explore.format(:counter, %{report | generated: 1, seeds: 4031..4031}) ==
               "explore counter: 1 trace (seeds 4031..4031), 0 failures, 2 skipped"
    end

    @passing %{
      generated: 100,
      replayed: 100,
      skipped: 0,
      seeds: 4031..4035,
      failures: [],
      error: nil,
      witnesses: []
    }

    test "format/2 prints witness rates" do
      report = %{
        @passing
        | witnesses: [
            %{name: "witOverLimit", hits: 35, traces: 100},
            %{name: "witResetAfterInc", hits: 100, traces: 100}
          ]
      }

      assert Explore.format(:counter, report) ==
               "explore counter: 100 traces (seeds 4031..4035), 0 failures, 0 skipped\n" <>
                 "witnesses: witOverLimit 35/100 (35.0%), witResetAfterInc 100/100 (100.0%)"
    end

    test "a witness never hit says never" do
      report = %{@passing | witnesses: [%{name: "witA", hits: 0, traces: 100}]}

      assert Explore.format(:counter, report) ==
               "explore counter: 100 traces (seeds 4031..4035), 0 failures, 0 skipped\n" <>
                 "witnesses: witA 0/100 (never)"
    end

    test "unknown counts" do
      assert Explore.format(:counter, %{@passing | witnesses: :unknown}) ==
               "explore counter: 100 traces (seeds 4031..4035), 0 failures, 0 skipped\n" <>
                 "witnesses: counts not found in Quint's output"
    end

    test "no witnesses line without witnesses" do
      assert Explore.format(:counter, @passing) ==
               "explore counter: 100 traces (seeds 4031..4035), 0 failures, 0 skipped"
    end

    test "no witnesses line before the first batch" do
      report = %{
        @passing
        | generated: 0,
          seeds: 4031..4031,
          witnesses: [%{name: "witA", hits: 0, traces: 0}],
          error: "quint run for :counter explore failed:\nboom"
      }

      assert Explore.format(:counter, report) ==
               "explore counter: 0 traces (seeds 4031..4031), 0 failures, 0 skipped\n\n" <>
                 "quint run for :counter explore failed:\nboom"
    end

    test "the witnesses line comes before an error" do
      report = %{
        @passing
        | witnesses: [%{name: "witA", hits: 1, traces: 3}],
          error: "quint run for :counter explore failed:\nboom"
      }

      assert Explore.format(:counter, report) ==
               "explore counter: 100 traces (seeds 4031..4035), 0 failures, 0 skipped\n" <>
                 "witnesses: witA 1/3 (33.3%)\n\n" <>
                 "quint run for :counter explore failed:\nboom"
    end

    test "a report with failures and an error" do
      dir = Path.join(File.cwd!(), "_build/test/ash_quint/explore/counter")

      failure = fn index, cut_at, reproduced ->
        %{
          seed: 4031,
          index: index,
          message: "counter regression 4031_#{index}: failed",
          candidate: Path.join(dir, "regression_4031_#{index}.itf.json"),
          cut_at: cut_at,
          reproduced: reproduced,
          quint: if(index != 4, do: "npx quint run m.qnt --seed=4031 (trace #{index})")
        }
      end

      report = %{
        generated: 100,
        replayed: 100,
        skipped: 0,
        seeds: 4031..4035,
        failures: [
          failure.(1, 5, true),
          failure.(2, nil, true),
          failure.(3, nil, false),
          failure.(4, nil, nil)
        ],
        error: "quint run for :counter explore failed:\nboom",
        witnesses: []
      }

      path = "_build/test/ash_quint/explore/counter/regression_4031_"
      promote = "promote:   MIX_ENV=test mix ash_quint.promote #{path}"

      assert Explore.format(:counter, report) ==
               """
               explore counter: 4 failures in 100 traces (seeds 4031..4035)

               counter regression 4031_1: failed
               candidate: #{path}1.itf.json (cut to 5 steps)
               quint:     npx quint run m.qnt --seed=4031 (trace 1)
               #{promote}1.itf.json

               counter regression 4031_2: failed
               candidate: #{path}2.itf.json (not cut)
               quint:     npx quint run m.qnt --seed=4031 (trace 2)
               #{promote}2.itf.json

               counter regression 4031_3: failed
               candidate: #{path}3.itf.json (did not reproduce on a second replay; full trace)
               quint:     npx quint run m.qnt --seed=4031 (trace 3)
               #{promote}3.itf.json

               counter regression 4031_4: failed
               candidate: #{path}4.itf.json (adapter raised; full trace)
               #{promote}4.itf.json

               quint run for :counter explore failed:
               boom\
               """

      one = %{report | failures: [failure.(1, 5, true)], error: nil}

      assert Explore.format(:counter, one) =~
               ~r/\Aexplore counter: 1 failure in 100 traces \(seeds 4031..4035\)\n\n/
    end
  end

  describe "with Quint" do
    @describetag :quint_cli
    @describetag timeout: 300_000

    defp quint_run(opts, settings, tmp_dir) do
      opts = Keyword.merge([config: "ash_quint.exs", batch: 20], opts)

      Explore.run(Map.merge(%{budget: nil, failures: 1}, settings), opts,
        build_dir: Path.join(tmp_dir, "build"),
        tmp_dir: Path.join(tmp_dir, "tmp")
      )
    end

    test "a counter session of two batches passes", %{tmp_dir: tmp_dir} do
      report =
        quint_run([model: :counter, adapter: CounterAdapter], %{runs: 40, seed: 1}, tmp_dir)

      assert %{generated: 40, replayed: 40, skipped: 0, failures: [], error: nil} = report
      assert report.seeds == 1..2
    end

    test "a counter session reports witness rates", %{tmp_dir: tmp_dir} do
      report =
        quint_run([model: :counter, adapter: CounterAdapter], %{runs: 40, seed: 1}, tmp_dir)

      assert [
               %{name: "witOverLimit", hits: over, traces: 40},
               %{name: "witResetAfterInc", hits: reset, traces: 40}
             ] = report.witnesses

      assert over in 0..40
      assert reset in 0..40

      assert [_summary, "witnesses: witOverLimit " <> _rest] =
               String.split(Explore.format(:counter, report), "\n")
    end

    test "an off-by-one counter candidate shrinks, promotes and fails the same way", %{
      tmp_dir: tmp_dir
    } do
      report =
        quint_run(
          [model: :counter, adapter: CounterAdapterOffByOne],
          %{runs: 20, seed: @counter_seed},
          tmp_dir
        )

      assert [%{reproduced: true, shrunk: %{from: from, steps: steps}} = failure] =
               report.failures

      assert steps < from
      assert failure.message =~ "counter regression #{failure.seed}_#{failure.index}, step "

      binary = File.read!(failure.candidate)
      assert Jason.decode!(binary)["#meta"]["status"] == "ok"
      assert {:ok, %{"shrunk" => %{"steps" => ^steps, "run" => run}}} = Gen.provenance(binary)
      assert run == failure.shrunk.run

      root = Path.join(tmp_dir, "root")
      File.mkdir_p!(root)
      File.cp!("ash_quint.exs", Path.join(root, "ash_quint.exs"))

      for example <- ~w(priv/examples/counter priv/examples/race) do
        File.mkdir_p!(Path.join(root, example))
        File.cp_r!(example, Path.join(root, example))
      end

      Mix.shell(Mix.Shell.Process)

      try do
        File.cd!(root, fn -> Promote.run([failure.candidate]) end)
      after
        Mix.shell(Mix.Shell.IO)
      end

      name = "#{failure.seed}_#{failure.index}"
      promoted = Path.join(root, "priv/examples/counter/traces/regression_#{name}.itf.json")

      # The promoted trace, replayed with the batch's seed, fails with Inc at
      # its last step.
      trace = Trace.load!(promoted, name: name, source: :regression, seed: failure.seed)
      model = Config.model!(Config.load!(), :counter)

      assert {:error, %{index: ^steps, action: "Inc"}} =
               Replay.run(
                 CounterAdapterOffByOne,
                 trace,
                 Model.replay_opts(model)
               )

      mod = Module.concat(__MODULE__, "Promoted#{System.unique_integer([:positive])}")

      File.cd!(root, fn ->
        Code.compile_string("""
        defmodule #{inspect(mod)} do
          use ExUnit.Case, register: false
          use AshQuint.Case, model: :counter, adapter: AshQuint.Test.CounterAdapterOffByOne
        end
        """)
      end)

      tests = Map.new(mod.__ex_unit__().tests, &{&1.name, &1.tags})
      assert %{quint: :regression} = tests[:"test regression #{name}"]

      # The promoted test fails with the message explore reported, then the
      # trace file, the quint command and the run explore printed.
      error =
        assert_raise ExUnit.AssertionError, fn ->
          File.cd!(root, fn -> apply(mod, :"test regression #{name}", [%{}]) end)
        end

      assert error.message ==
               failure.message <>
                 "\ntrace: priv/examples/counter/traces/regression_#{name}.itf.json" <>
                 "\nquint: " <> failure.quint <> "\nrun:   " <> run

      assert failure.quint =~
               " --backend=rust --witnesses witOverLimit witResetAfterInc " <>
                 "'--out-itf=explore_{seq}.itf.json' (trace "
    end

    test "race with the read-modify-write action finds the lost update", %{tmp_dir: tmp_dir} do
      report =
        quint_run(
          [model: :race, adapter: RaceAdapter, adapter_opts: [action: :inc]],
          %{runs: 100, seed: @race_seed, failures: 1},
          tmp_dir
        )

      assert [failure] = report.failures
      assert failure.message =~ "race regression #{failure.seed}_#{failure.index}, step "
    end
  end
end
