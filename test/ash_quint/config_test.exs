defmodule AshQuint.ConfigTest do
  use ExUnit.Case, async: true

  alias AshQuint.Config
  alias AshQuint.Config.Model

  @root "/proj"

  defp minimal(model_opts \\ [], top \\ []) do
    Keyword.merge(
      [
        quint: "0.33.1",
        models: [counter: Keyword.merge([seed: 1, random: [main: "step"]], model_opts)]
      ],
      top
    )
  end

  defp validate(config), do: Config.validate!(config, @root)

  defp counter(config), do: Config.model!(validate(config), :counter)

  defp assert_raises_config(config, message) do
    assert_raise Mix.Error, message, fn -> validate(config) end
  end

  test "defaults" do
    config = validate(minimal())

    assert %Config{
             quint: "0.33.1",
             quint_cmd: ["npx", "--yes", "@informalsystems/quint@{version}"],
             model_dir: "test/quint",
             fixture_dir: "test/fixtures/quint",
             on_missing_model: :fail,
             root: @root
           } = config

    assert %{counter: model} = config.models

    assert model == %Model{
             name: :counter,
             model: "test/quint/counter/model.qnt",
             tests: "test/quint/counter/model-tests.qnt",
             out: "test/fixtures/quint/counter",
             on_missing_model: :fail,
             seed: 1,
             action_path: ["lastAction"],
             result_path: ["lastResult"],
             pending_result: "Pending",
             op_field: "op",
             init_action: "Init",
             random: [main: "step"],
             witnesses: nil,
             scenarios: nil
           }
  end

  test "model_dir and fixture_dir set the bases" do
    model = counter(minimal([], model_dir: "q", fixture_dir: "f"))

    assert model.model == "q/counter/model.qnt"
    assert model.tests == "q/counter/model-tests.qnt"
    assert model.out == "f/counter"
  end

  test "per-model overrides win" do
    model =
      counter(
        minimal(
          model: "m/model.qnt",
          tests: "m/tests.qnt",
          out: "o",
          on_missing_model: :skip,
          action_path: ["last", "action"],
          result_path: ["last", "result"],
          pending_result: "InFlight",
          op_field: "id",
          init_action: "Start"
        )
      )

    assert %Model{
             model: "m/model.qnt",
             tests: "m/tests.qnt",
             out: "o",
             on_missing_model: :skip,
             action_path: ["last", "action"],
             result_path: ["last", "result"],
             pending_result: "InFlight",
             op_field: "id",
             init_action: "Start"
           } = model

    assert counter(minimal([], on_missing_model: :skip)).on_missing_model == :skip

    assert counter(minimal([on_missing_model: :fail], on_missing_model: :skip)).on_missing_model ==
             :fail
  end

  test "all sources and their options are accepted" do
    model =
      counter(
        minimal(
          random: [
            main: "step",
            init: "setup",
            step: "next_step",
            n_traces: 20,
            max_steps: 12,
            max_samples: 200
          ],
          witnesses: [
            main: "spec",
            init: "setup",
            step: "next_step",
            names: ["witA", "witB"],
            max_steps: 12,
            max_samples: 50_000
          ],
          scenarios: [main: "tests", match: "Test$"]
        )
      )

    assert model.random == [
             main: "step",
             init: "setup",
             step: "next_step",
             n_traces: 20,
             max_steps: 12,
             max_samples: 200
           ]

    assert model.witnesses == [
             main: "spec",
             init: "setup",
             step: "next_step",
             names: ["witA", "witB"],
             max_steps: 12,
             max_samples: 50_000
           ]

    assert model.scenarios == [main: "tests", match: "Test$"]
  end

  test "a model needs only one source" do
    config =
      validate(quint: "0.33.1", models: [counter: [seed: 1, scenarios: [main: "tests"]]])

    assert %Model{random: nil, witnesses: nil, scenarios: [main: "tests"]} =
             Config.model!(config, :counter)
  end

  test "paths in git-excluded directories are allowed" do
    model = counter(minimal(model: "agent-plans/x/spec/v3/model.qnt"))

    assert model.model == "agent-plans/x/spec/v3/model.qnt"
  end

  test "refuses paths outside the project" do
    assert_raises_config(
      minimal(out: "../x"),
      "ash_quint.exs: models.counter.out (../x) is outside the project"
    )

    assert_raises_config(
      minimal(model: "a/../../x"),
      "ash_quint.exs: models.counter.model (a/../../x) is outside the project"
    )

    assert_raises_config(
      minimal([], model_dir: "../q"),
      "ash_quint.exs: model_dir (../q) is outside the project"
    )
  end

  test "refuses default paths that a model name takes outside the project" do
    source = [seed: 1, random: [main: "counter"]]

    assert_raises_config(
      [quint: "0.33.1", models: ["../../../x": source]],
      "ash_quint.exs: models.../../../x.model (test/quint/../../../x/model.qnt) " <>
        "is outside the project"
    )

    assert_raises_config(
      [quint: "0.33.1", models: ["../../../x": [model: "m.qnt"] ++ source]],
      "ash_quint.exs: models.../../../x.tests (test/quint/../../../x/model-tests.qnt) " <>
        "is outside the project"
    )

    assert_raises_config(
      [quint: "0.33.1", models: ["../../../../x": [model: "m.qnt", tests: "t.qnt"] ++ source]],
      "ash_quint.exs: models.../../../../x.out (test/fixtures/quint/../../../../x) " <>
        "is outside the project"
    )

    assert %Model{model: "test/quint/../x/model.qnt"} =
             Config.model!(validate(quint: "0.33.1", models: ["../x": source]), :"../x")
  end

  test "refuses an out that is the project root" do
    assert_raises_config(
      minimal(out: "."),
      "ash_quint.exs: models.counter.out (.) is the project root"
    )

    assert_raises_config(
      minimal(out: "a/.."),
      "ash_quint.exs: models.counter.out (a/..) is the project root"
    )

    assert_raises_config(
      [
        quint: "0.33.1",
        models: [
          "../../..": [model: "m.qnt", tests: "t.qnt", seed: 1, random: [main: "counter"]]
        ]
      ],
      "ash_quint.exs: models.../../...out (test/fixtures/quint/../../..) is the project root"
    )
  end

  test "refuses two models with the same out" do
    source = [seed: 1, random: [main: "counter"]]

    assert_raises_config(
      [quint: "0.33.1", models: [a: [out: "o"] ++ source, b: [out: "./o/"] ++ source]],
      "ash_quint.exs: models.b.out (./o/) is the same directory as models.a.out"
    )

    config =
      validate(quint: "0.33.1", models: [a: [out: "o/a"] ++ source, b: [out: "o"] ++ source])

    assert config.models.a.out == "o/a"
    assert config.models.b.out == "o"
  end

  test "refuses absolute paths" do
    assert_raises_config(
      minimal(model: "/tmp/m.qnt"),
      "ash_quint.exs: models.counter.model must be relative to the project root"
    )

    assert_raises_config(
      minimal([], fixture_dir: "/tmp/f"),
      "ash_quint.exs: fixture_dir must be relative to the project root"
    )
  end

  test "refuses unknown keys" do
    assert_raises_config(minimal([], foo: 1), "ash_quint.exs: unknown key :foo")

    assert_raises_config(
      minimal(foo: 1),
      "ash_quint.exs: unknown key models.counter.foo"
    )

    assert_raises_config(
      minimal(random: [main: "step", invariants: ["inv"]]),
      "ash_quint.exs: unknown key models.counter.random.invariants"
    )

    assert_raises_config(
      minimal(witnesses: [main: "spec", names: ["w"], match: "x"]),
      "ash_quint.exs: unknown key models.counter.witnesses.match"
    )

    assert_raises_config(
      minimal(scenarios: [main: "tests", seed: 2]),
      "ash_quint.exs: unknown key models.counter.scenarios.seed"
    )
  end

  test "refuses duplicate keys" do
    assert_raises_config(
      [quint: "0.33.1", quint: "0.34.0", models: [counter: [seed: 1, random: [main: "s"]]]],
      "ash_quint.exs: duplicate key :quint"
    )

    assert_raises_config(
      [quint: "0.33.1", models: [counter: [seed: 1, seed: 2, random: [main: "s"]]]],
      "ash_quint.exs: duplicate key models.counter.seed"
    )
  end

  test "requires quint, seed and a source" do
    assert_raises_config(
      [models: [counter: [seed: 1, random: [main: "step"]]]],
      "ash_quint.exs: quint is required"
    )

    assert_raises_config([quint: "0.33.1"], "ash_quint.exs: models is required")

    assert_raises_config(
      [quint: "0.33.1", models: [counter: [random: [main: "step"]]]],
      "ash_quint.exs: models.counter.seed is required"
    )

    assert_raises_config(
      [quint: "0.33.1", models: [counter: [seed: 1]]],
      "ash_quint.exs: models.counter needs at least one of random, witnesses, scenarios"
    )

    assert_raises_config(
      minimal(random: [n_traces: 2]),
      "ash_quint.exs: models.counter.random.main is required"
    )

    assert_raises_config(
      minimal(witnesses: [main: "spec"]),
      "ash_quint.exs: models.counter.witnesses.names is required"
    )
  end

  test "refuses values of the wrong type" do
    assert_raises_config(
      "nope",
      "ash_quint.exs: must be a keyword list, got \"nope\""
    )

    assert_raises_config(
      minimal([], quint: :latest),
      "ash_quint.exs: quint must be a string, got :latest"
    )

    assert_raises_config(
      minimal([], quint_cmd: []),
      "ash_quint.exs: quint_cmd must be a non-empty list of strings, got []"
    )

    assert_raises_config(
      minimal([], on_missing_model: :ignore),
      "ash_quint.exs: on_missing_model must be :fail or :skip, got :ignore"
    )

    assert_raises_config(
      [quint: "0.33.1", models: []],
      "ash_quint.exs: models must be a non-empty keyword list, got []"
    )

    assert_raises_config(
      [quint: "0.33.1", models: [counter: "x"]],
      "ash_quint.exs: models.counter must be a keyword list, got \"x\""
    )

    assert_raises_config(
      minimal(seed: "1"),
      "ash_quint.exs: models.counter.seed must be an integer, got \"1\""
    )

    assert_raises_config(
      minimal(action_path: "lastAction"),
      "ash_quint.exs: models.counter.action_path must be a non-empty list of strings, " <>
        "got \"lastAction\""
    )

    assert_raises_config(
      minimal(model: 1),
      "ash_quint.exs: models.counter.model must be a string, got 1"
    )

    assert_raises_config(
      minimal(init_action: :init),
      "ash_quint.exs: models.counter.init_action must be a string, got :init"
    )

    assert_raises_config(
      minimal(pending_result: :pending),
      "ash_quint.exs: models.counter.pending_result must be a string, got :pending"
    )

    for result <- ["Accepted", "Rejected"] do
      assert_raises_config(
        minimal(pending_result: result),
        "ash_quint.exs: models.counter.pending_result can't be #{result}, " <>
          "which is already a result"
      )
    end

    assert_raises_config(
      minimal(op_field: ["op"]),
      ~s(ash_quint.exs: models.counter.op_field must be a string, got ["op"])
    )

    assert_raises_config(
      minimal(random: [main: "step", n_traces: 0]),
      "ash_quint.exs: models.counter.random.n_traces must be a positive integer, got 0"
    )

    assert_raises_config(
      minimal(witnesses: [main: "spec", names: []]),
      "ash_quint.exs: models.counter.witnesses.names must be a non-empty list of strings, got []"
    )

    assert_raises_config(
      minimal(scenarios: [main: "tests", match: ~r/Test$/]),
      "ash_quint.exs: models.counter.scenarios.match must be a string, got ~r/Test$/"
    )

    assert_raises_config(
      minimal(random: "step"),
      "ash_quint.exs: models.counter.random must be a keyword list, got \"step\""
    )
  end

  describe "backend" do
    test "backend defaults to unset" do
      config = validate(minimal())

      assert config.backend == nil
      assert Enum.all?(Map.values(config.models), &(&1.backend == nil))
    end

    test "a model inherits the top-level backend" do
      assert counter(minimal([], backend: "rust")).backend == "rust"
    end

    test "a model's backend overrides the top level" do
      assert counter(minimal([backend: "typescript"], backend: "rust")).backend == "typescript"
    end

    test "an unknown backend is an error" do
      assert_raises_config(
        minimal([], backend: "java"),
        ~s(ash_quint.exs: backend must be "rust" or "typescript", got "java")
      )

      assert_raises_config(
        minimal(backend: "java"),
        ~s(ash_quint.exs: models.counter.backend must be "rust" or "typescript", got "java")
      )
    end

    test "a non-string backend is an error" do
      assert_raises_config(
        minimal([], backend: :rust),
        ~s(ash_quint.exs: backend must be "rust" or "typescript", got :rust)
      )
    end
  end

  describe "shrink" do
    test "shrink: true is the empty keyword list" do
      assert counter(minimal(shrink: true)).shrink == []
    end

    test "shrink: options are kept" do
      assert counter(minimal(shrink: [apply: "apply", rounds: 5])).shrink ==
               [apply: "apply", rounds: 5]
    end

    test "shrink: false and unset are off" do
      assert counter(minimal(shrink: false)).shrink == nil
      assert counter(minimal()).shrink == nil
    end

    test "an unknown shrink key is an error" do
      assert_raises_config(
        minimal(shrink: [step: "x"]),
        "ash_quint.exs: unknown key models.counter.shrink.step"
      )
    end

    test "a duplicate shrink key is an error" do
      assert_raises_config(
        minimal(shrink: [rounds: 1, rounds: 2]),
        "ash_quint.exs: duplicate key models.counter.shrink.rounds"
      )
    end

    test "shrink: rounds must be positive" do
      assert_raises_config(
        minimal(shrink: [rounds: 0]),
        "ash_quint.exs: models.counter.shrink.rounds must be a positive integer, got 0"
      )
    end

    test "shrink: apply must be a string" do
      assert_raises_config(
        minimal(shrink: [apply: :apply]),
        "ash_quint.exs: models.counter.shrink.apply must be a string, got :apply"
      )
    end

    test "shrink: of another type is an error" do
      assert_raises_config(
        minimal(shrink: 1),
        "ash_quint.exs: models.counter.shrink must be true or a keyword list, got 1"
      )

      assert_raises_config(
        minimal(shrink: [:apply]),
        "ash_quint.exs: models.counter.shrink must be true or a keyword list, got [:apply]"
      )
    end
  end

  test "quint_cmd substitutes the version" do
    assert Config.quint_cmd(validate(minimal())) == [
             "npx",
             "--yes",
             "@informalsystems/quint@0.33.1"
           ]

    config =
      validate(
        minimal([],
          quint_cmd: ["mise", "exec", "npm:@informalsystems/quint@{version}", "--", "quint"]
        )
      )

    assert Config.quint_cmd(config) == [
             "mise",
             "exec",
             "npm:@informalsystems/quint@0.33.1",
             "--",
             "quint"
           ]
  end

  @tag :tmp_dir
  test "load! reads a file and reports a missing one", %{tmp_dir: tmp_dir} do
    File.write!(
      Path.join(tmp_dir, "ash_quint.exs"),
      inspect(minimal(), pretty: true)
    )

    config = Config.load!("ash_quint.exs", root: tmp_dir)
    assert %Config{root: ^tmp_dir, quint: "0.33.1"} = config
    assert %Model{seed: 1} = Config.model!(config, :counter)

    missing = Path.join(tmp_dir, "other.exs")

    assert_raise Mix.Error, "ash_quint.exs not found at #{missing}", fn ->
      Config.load!("other.exs", root: tmp_dir)
    end
  end

  @tag :tmp_dir
  test "load! refuses a file that isn't a keyword list", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "ash_quint.exs"), "%{quint: \"0.33.1\"}")

    assert_raise Mix.Error,
                 "ash_quint.exs: must be a keyword list, got %{quint: \"0.33.1\"}",
                 fn -> Config.load!("ash_quint.exs", root: tmp_dir) end
  end

  test "model! refuses an unknown model" do
    assert_raise Mix.Error, "model :nope is not configured in ash_quint.exs", fn ->
      Config.model!(validate(minimal()), :nope)
    end
  end

  describe "select!/2" do
    defp two_models do
      validate(
        quint: "0.33.1",
        models: [
          zeta: [seed: 1, random: [main: "step"]],
          alpha: [seed: 1, random: [main: "step"]]
        ]
      )
    end

    test "every model, sorted by name, when none are named" do
      assert Enum.map(Config.select!(two_models(), []), & &1.name) == [:alpha, :zeta]
    end

    test "the named models, in the order given" do
      assert Enum.map(Config.select!(two_models(), ["zeta", "alpha"]), & &1.name) ==
               [:zeta, :alpha]
    end

    test "refuses an unknown model without creating its atom" do
      assert_raise Mix.Error, "model :no_such_model_xyz is not configured in ash_quint.exs", fn ->
        Config.select!(two_models(), ["alpha", "no_such_model_xyz"])
      end

      assert_raise ArgumentError, fn -> String.to_existing_atom("no_such_model_xyz") end
    end
  end
end
