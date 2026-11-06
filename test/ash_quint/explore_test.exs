defmodule AshQuint.ExploreTest do
  # async: false: the run!/2 tests set ASH_QUINT_EXPLORE* env vars. The
  # "with Quint" tests run real Quint through npx: excluded by default, run
  # with `mix test --only quint_cli`.
  use ExUnit.Case, async: false

  alias AshQuint.{Explore, Gen, Manifest}
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

  # A runner that writes the fixture traces matching `glob`, cyclically, as
  # the batch's explore_<i>.itf.json files, and sends its args to the test.
  defp runner(glob \\ @ok_traces) do
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

      {"", 0}
    end
  end

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
               error: nil
             }
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
        error: nil
      }

      assert Explore.format(:counter, report) ==
               "explore counter: 100 traces (seeds 4031..4035), 0 failures, 2 skipped"

      assert Explore.format(:counter, %{report | generated: 1, seeds: 4031..4031}) ==
               "explore counter: 1 trace (seeds 4031..4031), 0 failures, 2 skipped"
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
          reproduced: reproduced
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
        error: "quint run for :counter explore failed:\nboom"
      }

      path = "_build/test/ash_quint/explore/counter/regression_4031_"
      promote = "promote:   MIX_ENV=test mix ash_quint.promote #{path}"

      assert Explore.format(:counter, report) ==
               """
               explore counter: 4 failures in 100 traces (seeds 4031..4035)

               counter regression 4031_1: failed
               candidate: #{path}1.itf.json (cut to 5 steps)
               #{promote}1.itf.json

               counter regression 4031_2: failed
               candidate: #{path}2.itf.json (not cut)
               #{promote}2.itf.json

               counter regression 4031_3: failed
               candidate: #{path}3.itf.json (did not reproduce on a second replay; full trace)
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

    test "an off-by-one adapter fails and its candidate promotes", %{tmp_dir: tmp_dir} do
      report =
        quint_run(
          [model: :counter, adapter: CounterAdapterOffByOne],
          %{runs: 20, seed: 1},
          tmp_dir
        )

      assert [%{reproduced: true, cut_at: cut_at} = failure] = report.failures
      assert is_integer(cut_at)
      assert failure.message =~ "counter regression #{failure.seed}_#{failure.index}, step "

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

      # The promoted test fails with the message explore reported.
      error =
        assert_raise ExUnit.AssertionError, fn ->
          File.cd!(root, fn -> apply(mod, :"test regression #{name}", [%{}]) end)
        end

      assert error.message == failure.message
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
