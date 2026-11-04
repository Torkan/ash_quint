defmodule AshQuint.GenTest do
  use ExUnit.Case, async: true

  alias AshQuint.Config
  alias AshQuint.Gen
  alias AshQuint.Manifest
  alias AshQuint.Trace

  @moduletag :tmp_dir

  @model_file "priv/x/model.qnt"
  @tests_file "priv/x/model-tests.qnt"

  defp config(root, model_opts \\ []) do
    opts =
      Keyword.merge(
        [
          model: @model_file,
          tests: @tests_file,
          out: "priv/x/traces",
          seed: 7,
          random: [main: "counter", n_traces: 2, max_steps: 5, max_samples: 20],
          witnesses: [main: "counter", names: ["witA"], max_steps: 6, max_samples: 100],
          scenarios: [main: "tests", match: "Test$"]
        ],
        model_opts
      )
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    Config.validate!([quint: "0.33.1", models: [counter: opts]], root)
  end

  defp write_models(root) do
    File.mkdir_p!(Path.join(root, "priv/x"))
    File.write!(Path.join(root, @model_file), "module counter {}\n")
    File.write!(Path.join(root, @tests_file), "module tests {}\n")
  end

  defp setup_root(%{tmp_dir: tmp_dir}) do
    root = Path.join(tmp_dir, "root")
    write_models(root)
    %{root: root, tmp: Path.join(tmp_dir, "gen")}
  end

  # A trace as Quint writes it: compact JSON, no trailing newline, with the
  # top-level #meta keys in Quint's order.
  defp itf(source, status, actions) do
    meta =
      Jason.OrderedObject.new([
        {"format", "ITF"},
        {"format-description", "https://apalache-mc.org/docs/adr/015adr-trace.html"},
        {"source", source},
        {"status", status},
        {"description", "Created by Quint on some day"},
        {"timestamp", 1_793_632_662_278}
      ])

    states =
      [{"Init", %{"#tup" => []}} | actions]
      |> Enum.with_index()
      |> Enum.map(fn {{tag, value}, index} ->
        Jason.OrderedObject.new([
          {"#meta", %{"index" => index}},
          {"lastAction", Jason.OrderedObject.new([{"tag", tag}, {"value", value}])},
          {"n", %{"#bigint" => Integer.to_string(index)}}
        ])
      end)

    Jason.encode!(
      Jason.OrderedObject.new([
        {"#meta", meta},
        {"vars", ["lastAction", "n"]},
        {"states", states}
      ])
    )
  end

  @inc {"Inc", %{"by" => %{"#bigint" => "1"}}}
  @reset {"Reset", "c1"}

  defp out_itf(args) do
    Enum.find_value(args, fn
      "--out-itf=" <> path -> path
      _arg -> nil
    end)
  end

  # Writes canned traces into each command's --out-itf path. `overrides`
  # maps :random, :witness or :scenario to a function of the args returning
  # `{output, exit}` (and writing whatever it likes).
  defp stub(test_pid, overrides \\ %{}) do
    fn cmd, args, opts ->
      send(test_pid, {:ran, cmd, args, opts})
      [_npx_flag, _package, kind | _rest] = args
      source = if kind == "test", do: @tests_file, else: @model_file

      key =
        cond do
          kind == "test" -> :scenario
          Enum.any?(args, &String.starts_with?(&1, "--invariant=")) -> :witness
          true -> :random
        end

      case Map.fetch(overrides, key) do
        {:ok, fun} -> fun.(args)
        :error -> default_run(key, out_itf(args), source)
      end
    end
  end

  defp default_run(:random, pattern, source) do
    write_pattern(pattern, "0", itf(source, "ok", [@inc, @inc]))
    write_pattern(pattern, "1", itf(source, "ok", [@inc, @reset, @inc]))
    {"random output", 0}
  end

  defp default_run(:witness, path, source) do
    File.write!(path, itf(source, "violation", [@inc]))
    {"[violation] Found an issue", 1}
  end

  defp default_run(:scenario, pattern, source) do
    pattern
    |> String.replace("{test}", "aTest")
    |> write_pattern("0", itf(source, "ok", [@inc, @reset]))

    pattern
    |> String.replace("{test}", "bTest")
    |> write_pattern("1", itf(source, "ok", [@inc]))

    {"2 passing", 0}
  end

  defp write_pattern(pattern, seq, content) do
    File.write!(String.replace(pattern, "{seq}", seq), content)
  end

  describe "commands/3" do
    test "commands for each source", %{tmp_dir: tmp_dir} do
      config = config(tmp_dir)
      model = config.models.counter
      cmd = ["npx", "--yes", "@informalsystems/quint@0.33.1"]

      assert Gen.commands(config, model, "/tmp/g") == [
               %{
                 kind: :random,
                 name: nil,
                 cmd: cmd,
                 args: [
                   "run",
                   @model_file,
                   "--main=counter",
                   "--seed=7",
                   "--max-steps=5",
                   "--max-samples=20",
                   "--n-traces=2",
                   "--out-itf=/tmp/g/random_{seq}.itf.json"
                 ],
                 out: "/tmp/g/random_{seq}.itf.json"
               },
               %{
                 kind: :witness,
                 name: "witA",
                 cmd: cmd,
                 args: [
                   "run",
                   @model_file,
                   "--main=counter",
                   "--seed=7",
                   "--max-steps=6",
                   "--max-samples=100",
                   "--invariant=not(witA)",
                   "--out-itf=/tmp/g/witness_witA.itf.json"
                 ],
                 out: "/tmp/g/witness_witA.itf.json"
               },
               %{
                 kind: :scenario,
                 name: nil,
                 cmd: cmd,
                 args: [
                   "test",
                   @tests_file,
                   "--main=tests",
                   "--match=Test$",
                   "--seed=7",
                   "--out-itf=/tmp/g/scenario_{test}_{seq}.itf.json"
                 ],
                 out: "/tmp/g/scenario_{test}_{seq}.itf.json"
               }
             ]
    end

    test "leaves out unset options and unset sources", %{tmp_dir: tmp_dir} do
      config =
        config(tmp_dir,
          random: [main: "counter"],
          witnesses: [main: "spec", names: ["w1", "w2"]],
          scenarios: nil
        )

      assert [random, w1, w2] = Gen.commands(config, config.models.counter, "/t")

      assert random.args == [
               "run",
               @model_file,
               "--main=counter",
               "--seed=7",
               "--out-itf=/t/random_{seq}.itf.json"
             ]

      assert w1.args == [
               "run",
               @model_file,
               "--main=spec",
               "--seed=7",
               "--invariant=not(w1)",
               "--out-itf=/t/witness_w1.itf.json"
             ]

      assert w2.name == "w2"

      config =
        config(tmp_dir,
          random: [main: "counter", init: "setup", step: "advance"],
          witnesses: [main: "counter", init: "setup", step: "advance", names: ["w1"]],
          scenarios: nil
        )

      assert [random, w1] = Gen.commands(config, config.models.counter, "/t")

      for command <- [random, w1] do
        assert [
                 "run",
                 @model_file,
                 "--main=counter",
                 "--seed=7",
                 "--init=setup",
                 "--step=advance" | _
               ] =
                 command.args
      end

      config = config(tmp_dir, random: nil, witnesses: nil, scenarios: [main: "tests"])

      assert [%{kind: :scenario, args: args}] = Gen.commands(config, config.models.counter, "/t")

      assert args == [
               "test",
               @tests_file,
               "--main=tests",
               "--seed=7",
               "--out-itf=/t/scenario_{test}_{seq}.itf.json"
             ]
    end
  end

  describe "normalize/1" do
    test "normalize drops description and timestamp only" do
      original = File.read!("test/fixtures/itf/run.itf.json")
      json = Jason.decode!(original, objects: :ordered_objects)
      %Jason.OrderedObject{values: meta} = json["#meta"]

      meta =
        Jason.OrderedObject.new(
          meta ++ [{"description", "Created by Quint"}, {"timestamp", 1_793_632_662_278}]
        )

      with_header = Jason.encode!(%{json | values: [{"#meta", meta} | tl(json.values)]})

      assert with_header =~ ~s("status":"ok","description":"Created by Quint","timestamp":)
      assert Gen.normalize(with_header) == original
      assert Gen.normalize(original) == original
    end

    test "keeps bignumber objects and nested #meta as they are" do
      original = File.read!("test/fixtures/itf/bignum.itf.json")
      assert Gen.normalize(original) == original
    end
  end

  describe "generate/3" do
    setup :setup_root

    test "names files and builds the manifest", %{root: root, tmp: tmp} do
      config = config(root)

      assert {:ok, %{counter: %{files: files, manifest: manifest}}} =
               Gen.generate(config, [config.models.counter], runner: stub(self()), tmp_dir: tmp)

      assert Map.keys(files) == [
               "random_0.itf.json",
               "random_1.itf.json",
               "scenario_aTest.itf.json",
               "scenario_bTest.itf.json",
               "witness_witA.itf.json"
             ]

      assert files["random_0.itf.json"] == Gen.normalize(itf(@model_file, "ok", [@inc, @inc]))
      refute files["witness_witA.itf.json"] =~ "timestamp"

      assert Manifest.decode!(manifest, "manifest.json") == %Manifest{
               quint: "0.33.1",
               seed: 7,
               models: %{
                 @model_file => Manifest.hash_file(Path.join(root, @model_file)),
                 @tests_file => Manifest.hash_file(Path.join(root, @tests_file))
               },
               traces: [
                 entry("random_0.itf.json", :random, "0", 2, %{"Inc" => 2}),
                 entry("random_1.itf.json", :random, "1", 3, %{"Inc" => 2, "Reset" => 1}),
                 entry("scenario_aTest.itf.json", :scenario, "aTest", 2, %{
                   "Inc" => 1,
                   "Reset" => 1
                 }),
                 entry("scenario_bTest.itf.json", :scenario, "bTest", 1, %{"Inc" => 1}),
                 entry("witness_witA.itf.json", :witness, "witA", 1, %{"Inc" => 1})
               ]
             }

      assert manifest == Manifest.encode(Manifest.decode!(manifest, "manifest.json"))
    end

    test "runs the Quint command in the project root", %{root: root, tmp: tmp} do
      config = config(root)
      Gen.generate(config, [config.models.counter], runner: stub(self()), tmp_dir: tmp)

      assert_received {:ran, "npx", ["--yes", "@informalsystems/quint@0.33.1", "run" | _], opts}

      assert opts == [cd: root]
    end

    test "the manifest leaves out the tests file without scenarios", %{root: root, tmp: tmp} do
      config = config(root, scenarios: nil)

      assert {:ok, %{counter: %{files: files, manifest: manifest}}} =
               Gen.generate(config, [config.models.counter], runner: stub(self()), tmp_dir: tmp)

      assert Map.keys(Manifest.decode!(manifest, "m").models) == [@model_file]
      refute Enum.any?(Map.keys(files), &String.starts_with?(&1, "scenario_"))
    end

    test "generation is deterministic", %{root: root, tmp: tmp} do
      config = config(root)
      opts = [runner: stub(self()), tmp_dir: tmp]

      assert Gen.generate(config, [config.models.counter], opts) ==
               Gen.generate(config, [config.models.counter], opts)
    end

    test "cleans up its temp files", %{root: root, tmp: tmp} do
      config = config(root)
      Gen.generate(config, [config.models.counter], runner: stub(self()), tmp_dir: tmp)
      assert File.ls!(tmp) == []
    end

    test "writes into a new temp dir with a random name", %{root: root, tmp: tmp} do
      config = config(root)
      Gen.generate(config, [config.models.counter], runner: stub(self()), tmp_dir: tmp)

      assert_received {:ran, _cmd, args, _opts}
      # <tmp>/ash_quint_gen_<hex>/0/random_{seq}.itf.json
      dir = args |> out_itf() |> Path.dirname() |> Path.dirname()

      assert Path.dirname(dir) == tmp
      assert Path.basename(dir) =~ ~r/\Aash_quint_gen_[0-9a-f]{32}\z/
    end

    test "witness not reached", %{root: root, tmp: tmp} do
      config = config(root)

      runner =
        stub(self(), %{
          witness: fn args ->
            File.write!(out_itf(args), itf(@model_file, "ok", [@inc]))
            {"[ok] No violation found", 0}
          end
        })

      assert Gen.generate(config, [config.models.counter], runner: runner, tmp_dir: tmp) ==
               {:error, "witness witA of :counter was not reached:\n[ok] No violation found"}
    end

    test "witness exiting non-zero without a violation", %{root: root, tmp: tmp} do
      config = config(root)

      runner =
        stub(self(), %{
          witness: fn args ->
            File.write!(out_itf(args), itf(@model_file, "ok", [@inc]))
            {"error: runtime error", 1}
          end
        })

      assert Gen.generate(config, [config.models.counter], runner: runner, tmp_dir: tmp) ==
               {:error, "witness witA of :counter was not reached:\nerror: runtime error"}
    end

    test "witness exiting 0 is not reached, whatever the file says", %{root: root, tmp: tmp} do
      config = config(root)

      runner =
        stub(self(), %{
          witness: fn args ->
            File.write!(out_itf(args), itf(@model_file, "violation", [@inc]))
            {"done", 0}
          end
        })

      assert Gen.generate(config, [config.models.counter], runner: runner, tmp_dir: tmp) ==
               {:error, "witness witA of :counter was not reached:\ndone"}
    end

    test "witness run error", %{root: root, tmp: tmp} do
      config = config(root)
      runner = stub(self(), %{witness: fn _args -> {"error: unknown name witA", 1} end})

      assert Gen.generate(config, [config.models.counter], runner: runner, tmp_dir: tmp) ==
               {:error, "witness witA of :counter was not reached:\nerror: unknown name witA"}
    end

    test "failing scenario", %{root: root, tmp: tmp} do
      config = config(root)
      runner = stub(self(), %{scenario: fn _args -> {"1 failing", 1} end})

      assert Gen.generate(config, [config.models.counter], runner: runner, tmp_dir: tmp) ==
               {:error, "quint test for :counter failed:\n1 failing"}
    end

    test "a scenario with two traces", %{root: root, tmp: tmp} do
      config = config(root)

      runner =
        stub(self(), %{
          scenario: fn args ->
            pattern = String.replace(out_itf(args), "{test}", "aTest")
            write_pattern(pattern, "0", itf(@tests_file, "ok", [@inc]))
            write_pattern(pattern, "1", itf(@tests_file, "ok", [@inc]))
            {"ok", 0}
          end
        })

      assert Gen.generate(config, [config.models.counter], runner: runner, tmp_dir: tmp) ==
               {:error, "scenario aTest of :counter produced more than one trace"}
    end

    test "failing random run", %{root: root, tmp: tmp} do
      config = config(root)
      runner = stub(self(), %{random: fn _args -> {"error: Invariant violated", 1} end})

      assert Gen.generate(config, [config.models.counter], runner: runner, tmp_dir: tmp) ==
               {:error, "quint run for :counter random failed:\nerror: Invariant violated"}
    end

    test "a trace that doesn't follow the model convention", %{root: root, tmp: tmp} do
      config = config(root)

      runner =
        stub(self(), %{
          random: fn args ->
            write_pattern(out_itf(args), "0", itf(@model_file, "ok", [{"Inc", 1}, {"Inc", 2}]))

            File.write!(
              String.replace(out_itf(args), "{seq}", "1"),
              ~s({"vars":[],"states":[{}, {}]})
            )

            {"ok", 0}
          end
        })

      assert Gen.generate(config, [config.models.counter], runner: runner, tmp_dir: tmp) ==
               {:error, "model :counter: random_1.itf.json, state 1: no action at lastAction"}
    end

    test "missing model file", %{root: root, tmp: tmp} do
      config = config(root, model: "priv/missing.qnt")

      assert Gen.generate(config, [config.models.counter], runner: stub(self()), tmp_dir: tmp) ==
               {:error, "model :counter: model file priv/missing.qnt is missing"}

      refute_received {:ran, _, _, _}
    end

    test "missing tests file, only with scenarios", %{root: root, tmp: tmp} do
      config = config(root, tests: "priv/missing-tests.qnt")

      assert Gen.generate(config, [config.models.counter], runner: stub(self()), tmp_dir: tmp) ==
               {:error, "model :counter: tests file priv/missing-tests.qnt is missing"}

      config = config(root, tests: "priv/missing-tests.qnt", scenarios: nil)

      assert {:ok, _} =
               Gen.generate(config, [config.models.counter], runner: stub(self()), tmp_dir: tmp)
    end

    test "quint not runnable", %{root: root, tmp: tmp} do
      config = config(root)
      runner = fn _cmd, _args, _opts -> raise ErlangError, original: :enoent end

      assert Gen.generate(config, [config.models.counter], runner: runner, tmp_dir: tmp) ==
               {:error,
                "could not run Quint (npx --yes @informalsystems/quint@0.33.1): executable not found"}
    end

    test "other runner errors are raised", %{root: root, tmp: tmp} do
      config = config(root)
      runner = fn _cmd, _args, _opts -> raise ErlangError, original: :eacces end

      assert_raise ErlangError, "Erlang error: :eacces", fn ->
        Gen.generate(config, [config.models.counter], runner: runner, tmp_dir: tmp)
      end

      assert File.ls!(tmp) == []
    end

    test "stops at the first failing model and returns nothing", %{root: root, tmp: tmp} do
      config =
        Config.validate!(
          [
            quint: "0.33.1",
            models: [
              a: [model: @model_file, seed: 1, random: [main: "counter"]],
              b: [model: "priv/none.qnt", seed: 1, random: [main: "counter"]]
            ]
          ],
          root
        )

      assert Gen.generate(config, [config.models.a, config.models.b],
               runner: stub(self()),
               tmp_dir: tmp
             ) == {:error, "model :b: model file priv/none.qnt is missing"}
    end
  end

  describe "entry/5" do
    setup :setup_root

    test "counts actions and, per action, result labels", %{root: root} do
      model = config(root).models.counter
      accepted = {:variant, "Accepted", {}}
      rejected = {:variant, "Rejected", "over_limit"}

      trace = %Trace{
        path: "t.itf.json",
        vars: ["lastAction", "lastResult", "n"],
        states: [
          state("Init", accepted),
          state("Inc", accepted),
          state("Inc", rejected),
          state("Inc", accepted),
          state("Reset", accepted)
        ]
      }

      assert Gen.entry("random_0.itf.json", :random, "0", trace, model) == %{
               file: "random_0.itf.json",
               source: :random,
               name: "0",
               steps: 4,
               actions: %{"Inc" => 3, "Reset" => 1},
               outcomes: %{
                 "Inc" => %{"accepted" => 2, "rejected:over_limit" => 1},
                 "Reset" => %{"accepted" => 1}
               }
             }
    end

    test "a model without results has no outcomes", %{root: root} do
      model = config(root).models.counter

      trace = %Trace{
        path: "t.itf.json",
        vars: ["lastAction", "n"],
        states: Enum.map(["Init", "Inc"], &Map.delete(state(&1, nil), "lastResult"))
      }

      assert %{actions: %{"Inc" => 1}, outcomes: %{}} =
               Gen.entry("random_0.itf.json", :random, "0", trace, model)
    end
  end

  describe "diff/2 and write!/2" do
    setup %{tmp_dir: tmp_dir} do
      out = Path.join(tmp_dir, "out")
      File.mkdir_p!(out)
      File.write!(Path.join(out, "random_0.itf.json"), "same")
      File.write!(Path.join(out, "random_1.itf.json"), "old")
      File.write!(Path.join(out, "random_9.itf.json"), "stale")
      File.write!(Path.join(out, "manifest.json"), "manifest")
      File.write!(Path.join(out, "README"), "keep me")

      generated = %{
        files: %{
          "random_0.itf.json" => "same",
          "random_1.itf.json" => "new",
          "witness_w.itf.json" => "added"
        },
        manifest: "manifest"
      }

      %{out: out, generated: generated}
    end

    test "diff reports added, changed and removed files and ignores others", %{
      out: out,
      generated: generated
    } do
      assert Gen.diff(out, generated) == %{
               added: ["witness_w.itf.json"],
               changed: ["random_1.itf.json"],
               removed: ["random_9.itf.json"]
             }

      assert Gen.diff(out, %{generated | manifest: "other"}).changed == [
               "manifest.json",
               "random_1.itf.json"
             ]
    end

    test "diff of a missing out dir adds everything", %{tmp_dir: tmp_dir, generated: generated} do
      assert Gen.diff(Path.join(tmp_dir, "nope"), generated) == %{
               added: [
                 "manifest.json",
                 "random_0.itf.json",
                 "random_1.itf.json",
                 "witness_w.itf.json"
               ],
               changed: [],
               removed: []
             }
    end

    test "write! replaces traces and the manifest and leaves other files", %{
      out: out,
      generated: generated,
      tmp_dir: tmp_dir
    } do
      Gen.write!(out, generated)

      assert Enum.sort(File.ls!(out)) == [
               "README",
               "manifest.json",
               "random_0.itf.json",
               "random_1.itf.json",
               "witness_w.itf.json"
             ]

      assert File.read!(Path.join(out, "random_1.itf.json")) == "new"
      assert File.read!(Path.join(out, "README")) == "keep me"
      assert Gen.diff(out, generated) == %{added: [], changed: [], removed: []}

      fresh = Path.join(tmp_dir, "a/b")
      Gen.write!(fresh, generated)
      assert Gen.diff(fresh, generated) == %{added: [], changed: [], removed: []}
    end
  end

  defp state(tag, result) do
    %{"lastAction" => {:variant, tag, %{}}, "lastResult" => result, "n" => 0}
  end

  defp entry(file, source, name, steps, actions) do
    %{file: file, source: source, name: name, steps: steps, actions: actions, outcomes: %{}}
  end
end
