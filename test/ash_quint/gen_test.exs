defmodule AshQuint.GenTest do
  use ExUnit.Case, async: true

  alias AshQuint.Config
  alias AshQuint.Config.Model
  alias AshQuint.Gen
  alias AshQuint.Interface
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

  defp out(args) do
    Enum.find_value(args, fn
      "--out=" <> path -> path
      _arg -> nil
    end)
  end

  @counter_ir "test/fixtures/quint_ir/counter.json"

  defp counter_interface do
    {:ok, interface} =
      @counter_ir
      |> File.read!()
      |> Jason.decode!()
      |> Interface.from_ir(action_path: ["lastAction"], result_path: ["lastResult"])

    interface
  end

  # Writes canned traces into each command's --out-itf path, and counter's
  # IR into a compile's --out path. `overrides` maps :random, :witness,
  # :scenario or :interface to a function of the args returning
  # `{output, exit}` (and writing whatever it likes).
  defp stub(test_pid, overrides \\ %{}) do
    fn cmd, args, opts ->
      send(test_pid, {:ran, cmd, args, opts})
      [_npx_flag, _package, kind | _rest] = args
      source = if kind == "test", do: @tests_file, else: @model_file

      key =
        cond do
          kind == "compile" -> :interface
          kind == "test" -> :scenario
          Enum.any?(args, &String.starts_with?(&1, "--invariant=")) -> :witness
          true -> :random
        end

      case Map.fetch(overrides, key) do
        {:ok, fun} -> fun.(args)
        :error when key == :interface -> default_run(key, out(args), source)
        :error -> default_run(key, out_itf(args), source)
      end
    end
  end

  defp default_run(:interface, path, _source) do
    File.cp!(@counter_ir, path)
    {"<ir>", 0}
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

    test "commands/3's random args are random_args/3's", %{tmp_dir: tmp_dir} do
      config = config(tmp_dir)
      model = config.models.counter
      [random | _] = Gen.commands(config, model, "/tmp/g")

      assert random.args ==
               Gen.random_args(model, model.seed, out: "/tmp/g/random_{seq}.itf.json")
    end

    test "random_args/3 overrides n_traces, max_samples and max_steps", %{tmp_dir: tmp_dir} do
      model = config(tmp_dir).models.counter

      assert Gen.random_args(model, 99,
               n_traces: 3,
               max_samples: 3,
               max_steps: 4,
               out: "x/e_{seq}.itf.json"
             ) == [
               "run",
               @model_file,
               "--main=counter",
               "--seed=99",
               "--max-steps=4",
               "--max-samples=3",
               "--n-traces=3",
               "--out-itf=x/e_{seq}.itf.json"
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

  describe "commands/3 with a backend" do
    test "commands/3 passes --backend to run, witness and scenario commands when set", %{
      tmp_dir: tmp_dir
    } do
      config = config(tmp_dir, backend: "rust")
      commands = Gen.commands(config, config.models.counter, "/t")

      assert Enum.map(commands, & &1.kind) == [:random, :witness, :scenario]

      for %{args: args} <- commands do
        assert Enum.count(args, &(&1 == "--backend=rust")) == 1
        backend = Enum.find_index(args, &(&1 == "--backend=rust"))
        assert backend < Enum.find_index(args, &String.starts_with?(&1, "--out-itf="))

        if invariant = Enum.find_index(args, &String.starts_with?(&1, "--invariant=")) do
          assert backend < invariant
        end
      end

      assert [_random, %{args: witness}, %{args: scenario}] = commands

      assert witness == [
               "run",
               @model_file,
               "--main=counter",
               "--seed=7",
               "--max-steps=6",
               "--max-samples=100",
               "--backend=rust",
               "--invariant=not(witA)",
               "--out-itf=/t/witness_witA.itf.json"
             ]

      assert scenario == [
               "test",
               @tests_file,
               "--main=tests",
               "--match=Test$",
               "--seed=7",
               "--backend=rust",
               "--out-itf=/t/scenario_{test}_{seq}.itf.json"
             ]
    end

    test "commands/3 passes no --backend when unset", %{tmp_dir: tmp_dir} do
      config = config(tmp_dir)

      for %{args: args} <- Gen.commands(config, config.models.counter, "/t") do
        refute Enum.any?(args, &String.starts_with?(&1, "--backend"))
      end
    end

    test "interface_command/3 never passes --backend", %{tmp_dir: tmp_dir} do
      config = config(tmp_dir, backend: "rust")
      %{args: args} = Gen.interface_command(config, config.models.counter, "/o")

      refute Enum.any?(args, &String.starts_with?(&1, "--backend"))
    end

    test "random_args/3 includes the backend", %{tmp_dir: tmp_dir} do
      model = config(tmp_dir, backend: "typescript").models.counter

      assert Gen.random_args(model, 5, out: "x") == [
               "run",
               @model_file,
               "--main=counter",
               "--seed=5",
               "--max-steps=5",
               "--max-samples=20",
               "--n-traces=2",
               "--backend=typescript",
               "--out-itf=x"
             ]
    end

    test "backend_args/1 is the --backend flag, or nothing", %{tmp_dir: tmp_dir} do
      assert Gen.backend_args(config(tmp_dir, backend: "rust").models.counter) == [
               "--backend=rust"
             ]

      assert Gen.backend_args(config(tmp_dir).models.counter) == []
    end
  end

  describe "interface_command/3" do
    test "the interface command uses random's main and the model file", %{tmp_dir: tmp_dir} do
      config = config(tmp_dir)

      assert Gen.interface_command(config, config.models.counter, "/t/0.interface.json") == %{
               kind: :interface,
               name: nil,
               cmd: ["npx", "--yes", "@informalsystems/quint@0.33.1"],
               args: [
                 "compile",
                 "--target=json",
                 "--main=counter",
                 @model_file,
                 "--out=/t/0.interface.json"
               ],
               out: "/t/0.interface.json"
             }
    end

    test "without random, witnesses' main; with scenarios only, the tests file", %{
      tmp_dir: tmp_dir
    } do
      config = config(tmp_dir, random: nil, witnesses: [main: "spec", names: ["w"]])

      assert %{args: ["compile", "--target=json", "--main=spec", @model_file, "--out=/o"]} =
               Gen.interface_command(config, config.models.counter, "/o")

      config = config(tmp_dir, random: nil, witnesses: nil)

      assert %{args: ["compile", "--target=json", "--main=tests", @tests_file, "--out=/o"]} =
               Gen.interface_command(config, config.models.counter, "/o")
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

  describe "cut/2" do
    test "keeps the states up to the index, and the rest in order" do
      binary = ~s({"vars":["x"],"#meta":{"status":"ok"},"states":[{"x":0},{"x":1},{"x":2}]})

      assert Gen.cut(binary, 1) ==
               ~s({"vars":["x"],"#meta":{"status":"ok"},"states":[{"x":0},{"x":1}]})

      assert Gen.cut(binary, 2) == binary
    end
  end

  describe "put_source/2" do
    test "replaces #meta.source in place, or appends it" do
      binary = ~s({"#meta":{"format":"ITF","source":"w.qnt","status":"ok"},"states":[]})

      assert Gen.put_source(binary, "m.qnt") ==
               ~s({"#meta":{"format":"ITF","source":"m.qnt","status":"ok"},"states":[]})

      assert Gen.put_source(~s({"#meta":{"status":"ok"},"states":[]}), "m.qnt") ==
               ~s({"#meta":{"status":"ok","source":"m.qnt"},"states":[]})
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
               version: 3,
               interface: counter_interface(),
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

    test "generate/3 records the model's backend in the manifest", %{root: root, tmp: tmp} do
      config = config(root, backend: "rust")

      assert {:ok, %{counter: %{manifest: manifest}}} =
               Gen.generate(config, [config.models.counter], runner: stub(self()), tmp_dir: tmp)

      assert Jason.decode!(manifest)["backend"] == "rust"

      config = config(root)

      assert {:ok, %{counter: %{manifest: manifest}}} =
               Gen.generate(config, [config.models.counter], runner: stub(self()), tmp_dir: tmp)

      refute Map.has_key?(Jason.decode!(manifest), "backend")
    end

    test "compiles after the traces and records the interface", %{root: root, tmp: tmp} do
      config = config(root)

      assert {:ok, %{counter: %{files: files, manifest: manifest}}} =
               Gen.generate(config, [config.models.counter], runner: stub(self()), tmp_dir: tmp)

      ran = collect_ran()
      assert length(ran) == 4
      [_npx, _pkg, "compile" | _] = compile = List.last(ran)
      assert Enum.all?(Enum.drop(ran, -1), &(Enum.at(&1, 2) != "compile"))
      # <tmp>/ash_quint_gen_<hex>/0.interface.json, beside the model's dir
      assert compile |> out() |> Path.basename() == "0.interface.json"

      assert Manifest.decode!(manifest, "m").interface == counter_interface()
      refute Enum.any?(Map.keys(files), &String.contains?(&1, "interface"))
    end

    test "a failing compile is an error with Quint's output", %{root: root, tmp: tmp} do
      config = config(root)
      runner = stub(self(), %{interface: fn _args -> {"parse error", 1} end})

      assert Gen.generate(config, [config.models.counter], runner: runner, tmp_dir: tmp) ==
               {:error, "quint compile for :counter failed:\nparse error"}
    end

    test "an unreadable IR is an error", %{root: root, tmp: tmp} do
      config = config(root)

      runner =
        stub(self(), %{
          interface: fn args ->
            File.write!(out(args), "{}")
            {"{}", 0}
          end
        })

      assert Gen.generate(config, [config.models.counter], runner: runner, tmp_dir: tmp) ==
               {:error,
                "model :counter: could not read the model interface from Quint 0.33.1's " <>
                  "JSON IR: no modules list"}
    end

    test "an IR file that is missing or isn't JSON is an error", %{root: root, tmp: tmp} do
      config = config(root)
      message = "model :counter: could not read the model interface from Quint 0.33.1's JSON IR: "

      runner =
        stub(self(), %{
          interface: fn args ->
            File.write!(out(args), "{")
            {"", 0}
          end
        })

      assert Gen.generate(config, [config.models.counter], runner: runner, tmp_dir: tmp) ==
               {:error, message <> "invalid JSON in the --out file"}

      runner = stub(self(), %{interface: fn _args -> {"", 0} end})

      assert Gen.generate(config, [config.models.counter], runner: runner, tmp_dir: tmp) ==
               {:error, message <> "no --out file (no such file or directory)"}
    end

    test "an action var that isn't a sum is an error", %{root: root, tmp: tmp} do
      config = config(root)

      ir = %{
        "modules" => [
          %{
            "name" => "counter",
            "declarations" => [%{"kind" => "var", "name" => "lastAction", "id" => 1}]
          }
        ],
        "types" => %{
          "1" => %{
            "type" => %{"kind" => "fun", "arg" => %{"kind" => "str"}, "res" => %{"kind" => "int"}}
          }
        }
      }

      runner =
        stub(self(), %{
          interface: fn args ->
            File.write!(out(args), Jason.encode!(ir))
            {"", 0}
          end
        })

      assert Gen.generate(config, [config.models.counter], runner: runner, tmp_dir: tmp) ==
               {:error,
                "model :counter: the action at lastAction must be a sum type, got str -> int"}
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
               },
               concurrent: false,
               max_in_flight: 0
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

  describe "provenance" do
    test "put_provenance adds #meta.ash_quint and keeps the rest" do
      trace = Gen.normalize(itf(@model_file, "ok", [@inc]))
      provenance = %{"seed" => 5, "index" => 1, "model" => "counter", "cut_at" => nil}
      promoted = Gen.put_provenance(trace, provenance)

      assert Gen.provenance(promoted) == {:ok, provenance}
      refute String.ends_with?(promoted, "\n")

      original = Jason.decode!(trace, objects: :ordered_objects)
      decoded = Jason.decode!(promoted, objects: :ordered_objects)

      assert Enum.map(decoded["#meta"].values, &elem(&1, 0)) ==
               Enum.map(original["#meta"].values, &elem(&1, 0)) ++ ["ash_quint"]

      assert Enum.map(decoded["#meta"]["ash_quint"].values, &elem(&1, 0)) ==
               ["cut_at", "index", "model", "seed"]

      assert Enum.map(decoded.values, &elem(&1, 0)) == ["#meta", "vars", "states"]
      assert decoded["vars"] == original["vars"]
      assert decoded["states"] == original["states"]

      assert Gen.put_provenance(trace, provenance) == promoted
      replaced = Gen.put_provenance(promoted, %{"seed" => 6})
      assert Gen.provenance(replaced) == {:ok, %{"seed" => 6}}

      assert Enum.map(
               Jason.decode!(replaced, objects: :ordered_objects)["#meta"].values,
               &elem(&1, 0)
             ) ==
               Enum.map(decoded["#meta"].values, &elem(&1, 0))
    end

    test "provenance of a plain trace is :error" do
      assert Gen.provenance(Gen.normalize(itf(@model_file, "ok", [@inc]))) == :error

      not_an_object =
        Jason.encode!(%{"#meta" => %{"ash_quint" => "x"}, "vars" => [], "states" => []})

      assert Gen.provenance(not_an_object) == :error
    end
  end

  describe "quint_line/2" do
    @args [
      "run",
      "priv/examples/counter/model.qnt",
      "--main=counter",
      "--seed=4031",
      "--max-steps=10",
      "--backend=rust"
    ]

    test "quint_line/2 builds a paste-ready command", %{tmp_dir: tmp_dir} do
      assert Gen.quint_line(config(tmp_dir), %{"args" => @args, "index" => 2}) ==
               "npx --yes @informalsystems/quint@0.33.1 run priv/examples/counter/model.qnt " <>
                 "--main=counter --seed=4031 --max-steps=10 --backend=rust " <>
                 "--out-itf=explore_{seq}.itf.json (trace 2)"
    end

    test "quint_line/2 quotes words with other characters", %{tmp_dir: tmp_dir} do
      args = ["run", "--invariant=not(witA)", "a b", "it's", "--x=a+b@c:d,{e}"]

      assert Gen.quint_line(config(tmp_dir), %{"args" => args, "index" => 0}) ==
               "npx --yes @informalsystems/quint@0.33.1 run '--invariant=not(witA)' 'a b' " <>
                 "'it'\\''s' --x=a+b@c:d,{e} --out-itf=explore_{seq}.itf.json (trace 0)"
    end

    test "quint_line/2 without args is nil", %{tmp_dir: tmp_dir} do
      assert Gen.quint_line(config(tmp_dir), %{"index" => 1}) == nil
    end

    test "quint_line/2 with malformed args or index is nil", %{tmp_dir: tmp_dir} do
      config = config(tmp_dir)

      assert Gen.quint_line(config, %{"args" => @args}) == nil
      assert Gen.quint_line(config, %{"args" => "run", "index" => 1}) == nil
      assert Gen.quint_line(config, %{"args" => ["run", 1], "index" => 1}) == nil
      assert Gen.quint_line(config, %{"args" => @args, "index" => "1"}) == nil
      assert Gen.quint_line(config, %{"args" => @args, "index" => -1}) == nil
    end
  end

  describe "regression traces" do
    setup :setup_root

    # A regression file in the counter's out, with provenance for seed 5,
    # index 1 and `hash` (the current model hash by default).
    defp put_regression(root, provenance \\ %{}) do
      hash = Manifest.hash_file(Path.join(root, @model_file))
      out = Path.join(root, "priv/x/traces")
      File.mkdir_p!(out)

      binary =
        itf(@model_file, "ok", [@inc, @reset])
        |> Gen.normalize()
        |> Gen.put_provenance(
          Map.merge(
            %{"model" => "counter", "model_hash" => hash, "seed" => 5, "index" => 1},
            provenance
          )
        )

      File.write!(Path.join(out, "regression_5_1.itf.json"), binary)
      {out, binary}
    end

    defp generate_counter(root, tmp) do
      config = config(root)

      {:ok, %{counter: generated}} =
        Gen.generate(config, [config.models.counter], runner: stub(self()), tmp_dir: tmp)

      generated
    end

    test "keeps regression traces in out byte for byte", %{root: root, tmp: tmp} do
      {out, binary} = put_regression(root)
      generated = generate_counter(root, tmp)

      assert generated.files["regression_5_1.itf.json"] == binary
      assert generated.notes == []

      assert %{source: :regression, name: "5_1", seed: 5, steps: 2} =
               generated.manifest
               |> Manifest.decode!("m")
               |> Map.fetch!(:traces)
               |> Enum.find(&(&1.file == "regression_5_1.itf.json"))

      Gen.write!(out, generated)
      assert File.read!(Path.join(out, "regression_5_1.itf.json")) == binary
      assert Gen.diff(out, generated) == %{added: [], changed: [], removed: []}
    end

    test "a regression trace from an earlier model is kept with a note", %{root: root, tmp: tmp} do
      {_out, binary} = put_regression(root, %{"model_hash" => "sha256:old"})
      generated = generate_counter(root, tmp)

      assert generated.files["regression_5_1.itf.json"] == binary

      assert generated.notes == [
               "counter: regression_5_1.itf.json was found against an earlier model; " <>
                 "delete it if it no longer applies"
             ]
    end

    test "a regression file without provenance is an error", %{root: root, tmp: tmp} do
      out = Path.join(root, "priv/x/traces")
      File.mkdir_p!(out)

      File.write!(
        Path.join(out, "regression_5_1.itf.json"),
        Gen.normalize(itf(@model_file, "ok", [@inc]))
      )

      config = config(root)

      assert Gen.generate(config, [config.models.counter], runner: stub(self()), tmp_dir: tmp) ==
               {:error,
                "model :counter: regression_5_1.itf.json has no #meta.ash_quint; " <>
                  "only mix ash_quint.promote writes regression traces"}
    end

    test "keeps regression traces under a root with glob characters", %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "root[1]")
      write_models(root)
      {out, binary} = put_regression(root)
      generated = generate_counter(root, Path.join(tmp_dir, "gen"))

      assert generated.files["regression_5_1.itf.json"] == binary
      Gen.write!(out, generated)
      assert File.read!(Path.join(out, "regression_5_1.itf.json")) == binary
    end

    test "a regression file that isn't JSON is an error", %{root: root, tmp: tmp} do
      out = Path.join(root, "priv/x/traces")
      File.mkdir_p!(out)
      File.write!(Path.join(out, "regression_5_1.itf.json"), "{")
      config = config(root)

      assert {:error, message} =
               Gen.generate(config, [config.models.counter], runner: stub(self()), tmp_dir: tmp)

      assert message =~
               ~r/\Amodel :counter: regression_5_1\.itf\.json is not valid JSON \(.+\); delete it if it no longer applies\z/
    end

    test "a regression trace the model no longer reads is an error", %{root: root, tmp: tmp} do
      out = Path.join(root, "priv/x/traces")
      File.mkdir_p!(out)
      hash = Manifest.hash_file(Path.join(root, @model_file))

      # The model's action variable is lastAction; this trace has none.
      binary =
        Jason.encode!(%{
          "#meta" => %{"format" => "ITF"},
          "vars" => ["n"],
          "states" => [%{"n" => 0}, %{"n" => 1}]
        })
        |> Gen.put_provenance(%{
          "model" => "counter",
          "model_hash" => hash,
          "seed" => 5,
          "index" => 1
        })

      File.write!(Path.join(out, "regression_5_1.itf.json"), binary)
      config = config(root)

      assert {:error, message} =
               Gen.generate(config, [config.models.counter], runner: stub(self()), tmp_dir: tmp)

      assert message =~
               ~r/\Amodel :counter: regression_5_1\.itf\.json no longer fits the model \(regression_5_1\.itf\.json, state 1: .+\); delete it if it no longer applies\z/
    end

    test "deleting a regression file drops its entry", %{root: root, tmp: tmp} do
      {out, _binary} = put_regression(root)
      Gen.write!(out, generate_counter(root, tmp))
      File.rm!(Path.join(out, "regression_5_1.itf.json"))

      generated = generate_counter(root, tmp)
      refute Map.has_key?(generated.files, "regression_5_1.itf.json")

      refute Enum.any?(
               Manifest.decode!(generated.manifest, "m").traces,
               &(&1.source == :regression)
             )

      Gen.write!(out, generated)
      refute File.exists?(Path.join(out, "regression_5_1.itf.json"))
    end

    test "a regression file whose provenance has no integer seed is an error", %{
      root: root,
      tmp: tmp
    } do
      put_regression(root, %{"seed" => "5"})
      config = config(root)

      assert Gen.generate(config, [config.models.counter], runner: stub(self()), tmp_dir: tmp) ==
               {:error,
                "model :counter: regression_5_1.itf.json: #meta.ash_quint.seed must be an integer"}
    end

    test "regression_entry! builds the entry with its seed", %{root: root} do
      {_out, binary} = put_regression(root)
      model = config(root).models.counter

      assert Gen.regression_entry!("regression_5_1.itf.json", binary, model) == %{
               file: "regression_5_1.itf.json",
               source: :regression,
               name: "5_1",
               seed: 5,
               steps: 2,
               actions: %{"Inc" => 1, "Reset" => 1},
               outcomes: %{},
               concurrent: false,
               max_in_flight: 0
             }
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

  describe "entry/5 with ops in flight" do
    @pending {:variant, "Pending", {}}
    @accepted {:variant, "Accepted", {}}

    defp op_state(tag, picks, result),
      do: %{"lastAction" => {:variant, tag, picks}, "lastResult" => result}

    defp start(op, result \\ @pending), do: op_state("IncStart", %{"op" => op}, result)
    defp done(op), do: op_state("IncDone", %{"op" => op}, @accepted)

    defp race_entry(states, model_opts \\ []) do
      states = [op_state("Init", {}, @accepted) | states]
      trace = %AshQuint.Trace{path: "t", vars: [], states: states}
      fields = [name: :race, model: "m", tests: "t", out: "o", on_missing_model: :fail, seed: 1]
      model = struct!(Model, fields ++ model_opts)
      Gen.entry("random_0.itf.json", :random, "0", trace, model)
    end

    test "counts the ops in flight at once" do
      entry = race_entry([start("o1"), start("o2"), done("o2"), start("o3"), done("o1")])

      assert entry == %{
               file: "random_0.itf.json",
               source: :random,
               name: "0",
               steps: 5,
               actions: %{"IncStart" => 3, "IncDone" => 2},
               outcomes: %{"IncStart" => %{"pending" => 3}, "IncDone" => %{"accepted" => 2}},
               concurrent: true,
               max_in_flight: 2
             }
    end

    test "one action that starts and completes counts pending and its outcomes" do
      inc = fn op, result -> op_state("Inc", %{"op" => op}, result) end
      rejected = {:variant, "Rejected", "over_limit"}

      entry =
        race_entry([
          inc.("o1", @pending),
          inc.("o2", @pending),
          inc.("o2", @accepted),
          inc.("o1", rejected),
          inc.("o1", @accepted)
        ])

      assert entry.actions == %{"Inc" => 5}

      assert entry.outcomes == %{
               "Inc" => %{"pending" => 2, "accepted" => 2, "rejected:over_limit" => 1}
             }

      assert %{concurrent: true, max_in_flight: 2} = entry
    end

    test "one op at a time is concurrent with max_in_flight 1" do
      entry = race_entry([start("o1"), done("o1"), start("o2"), done("o2")])
      assert %{concurrent: true, max_in_flight: 1} = entry
    end

    test "an op advanced with Pending stays one op" do
      assert %{max_in_flight: 1} = race_entry([start("o1"), start("o1"), done("o1")])
    end

    test "a trace without Pending isn't concurrent, even with op fields" do
      entry = race_entry([start("o1", @accepted), done("o1")])
      assert %{concurrent: false, max_in_flight: 0} = entry
    end

    test "reads the model's pending_result and op_field" do
      in_flight = {:variant, "InFlight", {}}
      states = [op_state("IncStart", %{"id" => "a"}, in_flight)]

      assert %{max_in_flight: 1} =
               race_entry(states, pending_result: "InFlight", op_field: "id")

      assert_raise ArgumentError, ~r/random_0.itf.json, state 1: result at lastResult/, fn ->
        race_entry(states)
      end
    end
  end

  defp entry(file, source, name, steps, actions) do
    %{
      file: file,
      source: source,
      name: name,
      steps: steps,
      actions: actions,
      outcomes: %{},
      concurrent: false,
      max_in_flight: 0
    }
  end

  defp collect_ran(acc \\ []) do
    receive do
      {:ran, _cmd, args, _opts} -> collect_ran([args | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
