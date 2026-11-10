defmodule AshQuint.CaseTest do
  use ExUnit.Case, async: true

  alias AshQuint.Test.{
    ConcurrentToyAdapter,
    ConcurrentToyAdapterBlind,
    PostconditionToyAdapterBlind,
    ToyAdapter,
    ToyAdapterBlindReset,
    ToyAdapterConstant,
    ToyAdapterLimit
  }

  @config "test/fixtures/case/ash_quint.exs"

  # Compiles a test module that uses AshQuint.Case for `model` and returns
  # the module. The toy adapter serves several toy models, so against the
  # :promoted interface the adapter check warns about its other actions
  # (see "adapter check"); those warnings are captured here.
  defp compile(model, preamble \\ "use ExUnit.Case, register: false", extra \\ "") do
    mod = Module.concat(__MODULE__, "Gen#{System.unique_integer([:positive])}")

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      Code.compile_string("""
      defmodule #{inspect(mod)} do
        #{preamble}

        use AshQuint.Case,
          config: #{inspect(@config)},
          model: #{inspect(model)},
          adapter: AshQuint.Test.ToyAdapter#{extra}
      end
      """)
    end)

    mod
  end

  defp compile_error(model, preamble \\ "use ExUnit.Case, register: false") do
    assert_raise CompileError, fn -> compile(model, preamble) end
  end

  defp run_test(mod, name), do: apply(mod, :"test #{name}", [%{}])

  defp tests(mod), do: Map.new(mod.__ex_unit__().tests, &{&1.name, &1.tags})

  test "defines one test per trace with tags" do
    tests = tests(compile(:ok))

    assert Enum.sort(Map.keys(tests)) == [
             :"test random 0",
             :"test scenario incTest",
             :"test traces for ok are current"
           ]

    assert %{quint: :random, quint_model: :ok} = tests[:"test random 0"]
    assert %{quint: :scenario, quint_model: :ok} = tests[:"test scenario incTest"]
    assert %{quint_model: :ok} = tags = tests[:"test traces for ok are current"]
    refute Map.has_key?(tags, :quint)
    refute Map.has_key?(tags, :skip)
  end

  test "generated trace tests replay" do
    mod = compile(:ok)
    assert run_test(mod, "random 0") == :ok
    assert run_test(mod, "scenario incTest") == :ok
  end

  test "adapter_opts reach init/2 and a failing replay fails its test" do
    mod =
      compile(:ok, "use ExUnit.Case, register: false", ", adapter_opts: [faults: [:off_by_one]]")

    error = assert_raise ExUnit.AssertionError, fn -> run_test(mod, "scenario incTest") end

    assert error.message ==
             "ok scenario incTest, step 1 (Inc), seed 7: key \"count\":\n  expected: 2\n  actual:   3\n" <>
               ~s(model step: Inc %{"by" => 2}, result :accepted\n) <>
               "trace: test/fixtures/case/ok/scenario_incTest.itf.json"
  end

  describe "context lines" do
    defp failing(model) do
      compile(
        model,
        "use ExUnit.Case, register: false",
        ", adapter_opts: [faults: [:off_by_one]]"
      )
    end

    defp failure_lines(mod, name) do
      error = assert_raise ExUnit.AssertionError, fn -> run_test(mod, name) end
      String.split(error.message, "\n")
    end

    test "a trace test's failure names the trace file" do
      assert List.last(failure_lines(failing(:ok), "random 0")) ==
               "trace: test/fixtures/case/ok/random_0.itf.json"
    end

    test "a regression with provenance prints its quint command" do
      assert Enum.take(failure_lines(failing(:promoted), "regression 4031_2"), -3) == [
               ~s(model step: Inc %{"by" => 1}, result :accepted),
               "trace: test/fixtures/case/promoted/regression_4031_2.itf.json",
               "quint: npx --yes @informalsystems/quint@0.33.1 run " <>
                 "test/fixtures/case/promoted/model.qnt --main=ok --seed=4031 " <>
                 "'--out-itf=explore_{seq}.itf.json' (trace 2)"
             ]
    end

    test "a shrunk regression prints its run" do
      assert Enum.take(failure_lines(failing(:shrink), "regression 4031_2"), -4) == [
               ~s(model step: Inc %{"by" => 1}, result :accepted),
               "trace: test/fixtures/case/shrink/regression_4031_2.itf.json",
               "quint: npx --yes @informalsystems/quint@0.33.1 run " <>
                 "test/fixtures/case/shrink/model.qnt --main=toy --seed=4031 " <>
                 "'--out-itf=explore_{seq}.itf.json' (trace 2)",
               "run:   init.then(inc(1))"
             ]
    end

    test "a scenario trace has no quint line" do
      assert Enum.take(failure_lines(failing(:promoted), "scenario incTest"), -2) == [
               ~s(model step: Inc %{"by" => 2}, result :accepted),
               "trace: test/fixtures/case/promoted/scenario_incTest.itf.json"
             ]
    end
  end

  test "a regression entry gets its own test with its seed" do
    tests = tests(compile(:promoted))

    assert Enum.sort(Map.keys(tests)) == [
             :"test regression 4031_2",
             :"test scenario incTest",
             :"test traces for promoted are current"
           ]

    assert %{quint: :regression, quint_model: :promoted} = tests[:"test regression 4031_2"]
    assert run_test(compile(:promoted), "regression 4031_2") == :ok

    mod =
      compile(
        :promoted,
        "use ExUnit.Case, register: false",
        ", adapter_opts: [faults: [:off_by_one]]"
      )

    error = assert_raise ExUnit.AssertionError, fn -> run_test(mod, "regression 4031_2") end
    assert error.message =~ ~r/^promoted regression 4031_2, step 1 \(Inc\), seed 4031: /

    error = assert_raise ExUnit.AssertionError, fn -> run_test(mod, "scenario incTest") end
    assert error.message =~ ~r/^promoted scenario incTest, step 1 \(Inc\), seed 7: /
  end

  test "staleness passes when hashes match" do
    assert run_test(compile(:ok), "traces for ok are current")
  end

  test "changed model hash fails the staleness test" do
    error =
      assert_raise ExUnit.AssertionError, fn ->
        run_test(compile(:stale), "traces for stale are current")
      end

    assert error.message ==
             "traces for :stale are stale: test/fixtures/case/stale/model.qnt changed; " <>
               "run mix ash_quint.gen stale"
  end

  test "missing model fails by default" do
    mod = compile(:missing_fail)

    error =
      assert_raise ExUnit.AssertionError, fn ->
        run_test(mod, "traces for missing_fail are current")
      end

    assert error.message ==
             "model file test/fixtures/case/missing_fail/model.qnt for :missing_fail is missing; " <>
               "set on_missing_model: :skip if models aren't committed"

    refute Map.has_key?(tests(mod)[:"test traces for missing_fail are current"], :skip)
    assert run_test(mod, "scenario incTest") == :ok
  end

  test "missing model is skipped with :skip" do
    mod = compile(:missing_skip)

    assert tests(mod)[:"test traces for missing_skip are current"].skip ==
             "model file test/fixtures/case/missing_skip/model.qnt for :missing_skip is missing"

    assert run_test(mod, "scenario incTest") == :ok
  end

  @tag :tmp_dir
  test "a model file removed after compiling passes the staleness test only with :skip",
       %{tmp_dir: tmp_dir} do
    models = [{"model.qnt", "sha256:00"}]

    assert AshQuint.Case.__check_current__(:gone, tmp_dir, models, :skip) == :ok

    error =
      assert_raise ExUnit.AssertionError, fn ->
        AshQuint.Case.__check_current__(:gone, tmp_dir, models, :fail)
      end

    assert error.message ==
             "model file model.qnt for :gone is missing; " <>
               "set on_missing_model: :skip if models aren't committed"
  end

  test "unknown model is a compile error" do
    assert compile_error(:nope).description == "model :nope is not configured in ash_quint.exs"
  end

  test "missing manifest is a compile error" do
    assert compile_error(:no_manifest).description ==
             "no manifest for :no_manifest at test/fixtures/case/no_manifest/manifest.json; " <>
               "run mix ash_quint.gen no_manifest"
  end

  test "empty manifest is a compile error" do
    assert compile_error(:empty).description ==
             "manifest for :empty at test/fixtures/case/empty/manifest.json has no traces; " <>
               "run mix ash_quint.gen empty"
  end

  test "requires ExUnit.Case first" do
    assert compile_error(:ok, "").description ==
             "use ExUnit.Case (or a case template that uses it) before AshQuint.Case"
  end

  test "an invalid config is a compile error" do
    mod = Module.concat(__MODULE__, "Gen#{System.unique_integer([:positive])}")

    error =
      assert_raise CompileError, fn ->
        Code.compile_string("""
        defmodule #{inspect(mod)} do
          use ExUnit.Case, register: false
          use AshQuint.Case, config: "nope.exs", model: :ok, adapter: AshQuint.Test.ToyAdapter
        end
        """)
      end

    assert error.description == "ash_quint.exs not found at #{Path.expand("nope.exs")}"
  end

  test "model: and adapter: are required" do
    for {opts, key} <- [{"adapter: X", :model}, {"model: :ok", :adapter}] do
      mod = Module.concat(__MODULE__, "Gen#{System.unique_integer([:positive])}")

      error =
        assert_raise CompileError, fn ->
          Code.compile_string("""
          defmodule #{inspect(mod)} do
            use ExUnit.Case, register: false
            use AshQuint.Case, config: #{inspect(@config)}, #{opts}
          end
          """)
        end

      assert error.description == "use AshQuint.Case needs the #{inspect(key)} option"
    end
  end

  # Compiles a test module for the :ok fixture with `adapter` and the
  # `sensitivity:` option given as source.
  defp compile_sensitivity(adapter, sensitivity) do
    mod = Module.concat(__MODULE__, "Gen#{System.unique_integer([:positive])}")

    Code.compile_string("""
    defmodule #{inspect(mod)} do
      use ExUnit.Case, register: false

      use AshQuint.Case,
        config: #{inspect(@config)},
        model: :ok,
        adapter: #{inspect(adapter)},
        sensitivity: #{sensitivity}
    end
    """)

    mod
  end

  defp sensitivity_failure(adapter, sensitivity) do
    mod = compile_sensitivity(adapter, sensitivity)
    error = assert_raise ExUnit.AssertionError, fn -> run_test(mod, "sensitivity of ok") end
    error.message
  end

  test "sensitivity: true adds a passing sensitivity test" do
    mod = compile_sensitivity(ToyAdapter, "true")

    assert %{quint_model: :ok, quint_sensitivity: :ok} =
             tags = tests(mod)[:"test sensitivity of ok"]

    refute Map.has_key?(tags, :quint)
    assert run_test(mod, "sensitivity of ok") == :ok
  end

  test "without sensitivity: there is no sensitivity test" do
    refute Map.has_key?(tests(compile(:ok)), :"test sensitivity of ok")

    refute Map.has_key?(
             tests(compile_sensitivity(ToyAdapter, "false")),
             :"test sensitivity of ok"
           )
  end

  test "sensitivity test fails listing survivors" do
    assert sensitivity_failure(ToyAdapterBlindReset, "true") ==
             "sensitivity of :ok:\ndropped Reset at random 0 step 3 was not detected"
  end

  test "untested key fails" do
    assert sensitivity_failure(ToyAdapterLimit, "true") ==
             "sensitivity of :ok:\nkey \"limit\" never changes in any trace"
  end

  test "allow_untested silences listed keys" do
    mod = compile_sensitivity(ToyAdapterLimit, ~s([allow_untested: [keys: ["limit"]]]))
    assert run_test(mod, "sensitivity of ok") == :ok
  end

  test "allow_untested silences listed actions" do
    allowed = ~s([allow_untested: [keys: ["limit"], actions: ["Inc", "Reset"], vars: ["count"]]])
    assert run_test(compile_sensitivity(ToyAdapterConstant, allowed), "sensitivity of ok") == :ok

    assert sensitivity_failure(
             ToyAdapterConstant,
             ~s([allow_untested: [keys: ["limit"], actions: ["Inc"], vars: ["count"]]])
           ) == "sensitivity of :ok:\nno step of Reset changes the state"
  end

  test "allow_untested silences actions whose postcondition drop survives" do
    assert sensitivity_failure(PostconditionToyAdapterBlind, "true") ==
             "sensitivity of :ok:\nno step of Reset changes the state"

    allowed = ~s([allow_untested: [actions: ["Reset"]]])
    mod = compile_sensitivity(PostconditionToyAdapterBlind, allowed)
    assert run_test(mod, "sensitivity of ok") == :ok
  end

  test "an unprojected variable fails the sensitivity test" do
    message =
      sensitivity_failure(
        ToyAdapterConstant,
        ~s([allow_untested: [keys: ["limit"], actions: ["Inc", "Reset"]]])
      )

    assert message == "sensitivity of :ok:\nvariable \"count\" is never projected"
  end

  test "stale vars entries fail" do
    assert sensitivity_failure(ToyAdapter, ~s([allow_untested: [vars: ["count"]]])) ==
             """
             sensitivity of :ok:
             variable "count" is allowed untested but is projected; \
             remove it from allow_untested\
             """

    assert sensitivity_failure(ToyAdapter, ~s([allow_untested: [vars: ["nope"]]])) ==
             """
             sensitivity of :ok:
             variable "nope" is allowed untested but isn't a model variable; \
             remove it from allow_untested\
             """
  end

  test "vars accepts ~w sigils" do
    allowed = "[allow_untested: [keys: ~w(limit), actions: ~w(Inc Reset), vars: ~w(count)]]"
    assert run_test(compile_sensitivity(ToyAdapterConstant, allowed), "sensitivity of ok") == :ok
  end

  test "vars must be strings" do
    error =
      assert_raise CompileError, fn ->
        compile_sensitivity(ToyAdapter, "[allow_untested: [vars: [:count]]]")
      end

    assert error.description ==
             "allow_untested vars must be a literal list of strings or a ~w sigil, got [:count]"
  end

  test "allow_untested accepts ~w and ~W sigils" do
    for allowed <- [
          "[allow_untested: [keys: ~w(limit), actions: ~w(Inc Reset), vars: ~w(count)]]",
          "[allow_untested: [keys: ~W(limit), actions: ~W(Inc Reset)s, vars: ~W(count)]]"
        ] do
      mod = compile_sensitivity(ToyAdapterConstant, allowed)
      assert run_test(mod, "sensitivity of ok") == :ok
    end
  end

  test "stale allow_untested entries fail" do
    assert sensitivity_failure(
             ToyAdapter,
             ~s([allow_untested: [keys: ["count"], actions: ["Inc"]]])
           ) ==
             """
             sensitivity of :ok:
             key "count" is allowed untested but is tested; remove it from allow_untested
             action "Inc" is allowed untested but is tested; remove it from allow_untested\
             """
  end

  test "unknown allow_untested entries fail" do
    assert sensitivity_failure(
             ToyAdapter,
             ~s([allow_untested: [keys: ["nope"], actions: ["Peek"]]])
           ) ==
             """
             sensitivity of :ok:
             key "nope" is allowed untested but isn't in any projection; \
             remove it from allow_untested
             action "Peek" is allowed untested but makes no system call in any trace; \
             remove it from allow_untested\
             """
  end

  test "allow_untested lines follow the untested ones" do
    assert sensitivity_failure(ToyAdapterLimit, ~s([allow_untested: [actions: ["Inc"]]])) ==
             """
             sensitivity of :ok:
             key "limit" never changes in any trace
             action "Inc" is allowed untested but is tested; remove it from allow_untested\
             """
  end

  test "invalid sensitivity options are compile errors" do
    for {source, description} <- [
          {"[allow: []]", "unknown sensitivity option :allow; expected allow_untested"},
          {"[allow_untested: [key: []]]",
           "unknown allow_untested option :key; expected keys, actions, interleavings or vars"},
          {"[allow_untested: [keys: [:count]]]",
           "allow_untested keys must be a literal list of strings or a ~w sigil, got [:count]"},
          {"[allow_untested: [actions: \"Peek\"]]",
           "allow_untested actions must be a literal list of strings or a ~w sigil, " <>
             "got \"Peek\""},
          {"[allow_untested: [keys: ~w(count)a]]",
           "allow_untested keys must be a literal list of strings or a ~w sigil, " <>
             "got ~w(count)a"},
          {~S|[allow_untested: [keys: ~w(#{key})]]|,
           "allow_untested keys must be a literal list of strings or a ~w sigil, " <>
             ~S|got ~w(#{key})|},
          {"[allow_untested: [keys: @keys]]",
           "allow_untested keys must be a literal list of strings or a ~w sigil, got @keys"},
          {"[allow_untested: :all]",
           "allow_untested must be a keyword list of keys, actions, interleavings and vars, " <>
             "got :all"},
          {"[1]",
           "sensitivity must be true, false or [allow_untested: [keys: [...], actions: [...]]], " <>
             "got [1]"},
          {"\"yes\"",
           "sensitivity must be true, false or [allow_untested: [keys: [...], actions: [...]]], " <>
             "got \"yes\""}
        ] do
      error = assert_raise CompileError, fn -> compile_sensitivity(ToyAdapter, source) end
      assert error.description == description
    end
  end

  test "external resources" do
    resources = compile(:ok).__info__(:attributes) |> Keyword.get_values(:external_resource)
    dir = Path.expand("test/fixtures/case/ok")

    for path <- [
          Path.expand(@config),
          Path.join(dir, "manifest.json"),
          Path.join(dir, "random_0.itf.json"),
          Path.join(dir, "scenario_incTest.itf.json"),
          Path.join(dir, "model.qnt")
        ] do
      assert path in List.flatten(resources)
    end
  end

  test "a missing model file is not an external resource" do
    resources =
      compile(:missing_skip).__info__(:attributes)
      |> Keyword.get_values(:external_resource)
      |> List.flatten()

    refute Path.expand("test/fixtures/case/missing_skip/model.qnt") in resources
    assert Path.expand("test/fixtures/case/missing_skip/manifest.json") in resources
  end

  describe "explore:" do
    test "the explore test is tagged and has no timeout" do
      tests = tests(compile(:ok, "use ExUnit.Case, register: false", ", explore: true"))

      assert %{quint_explore: :ok, timeout: :infinity} = tags = tests[:"test explore ok"]

      # Not quint_model: `mix test --only quint_model:ok` would run it.
      refute Map.has_key?(tags, :quint_model)
      refute Map.has_key?(tags, :quint)

      tests =
        tests(compile(:ok, "use ExUnit.Case, register: false", ", explore: [max_steps: 4]"))

      assert Map.has_key?(tests, :"test explore ok")
    end

    test "no explore test without explore:" do
      for extra <- ["", ", explore: false"] do
        tests = tests(compile(:ok, "use ExUnit.Case, register: false", extra))
        refute Enum.any?(Map.keys(tests), &(Atom.to_string(&1) =~ "explore"))
      end
    end

    test "explore: compile errors" do
      for {model, extra, description} <- [
            {:ok, "[foo: 1]", "unknown explore option :foo; expected max_steps or batch"},
            {:ok, "[batch: 0]", "explore option batch must be a positive integer, got 0"},
            {:ok, "[max_steps: @steps]",
             "explore option max_steps must be a positive integer, got @steps"},
            {:ok, ":yes",
             "explore must be true, false or a keyword list of max_steps and batch, got :yes"},
            {:ok, "[1]",
             "explore must be true, false or a keyword list of max_steps and batch, got [1]"},
            {:concurrent, "true", "explore needs random: for :concurrent in ash_quint.exs"}
          ] do
        error =
          assert_raise CompileError, fn ->
            compile(model, "use ExUnit.Case, register: false", ", explore: #{extra}")
          end

        assert error.description == description
      end
    end
  end

  describe "sandbox:" do
    # No such repo: Ecto.Adapters.SQL.Sandbox.checkout/1 raises on it,
    # which shows where the option reaches (the Postgres tests run it).
    @no_repo ", sandbox: AshQuint.Test.NoRepo"

    test "reaches the sensitivity check, not the trace tests" do
      mod = compile(:ok, "use ExUnit.Case, register: false", ", sensitivity: true" <> @no_repo)

      assert run_test(mod, "random 0") == :ok
      assert run_test(mod, "scenario incTest") == :ok

      error = assert_raise UndefinedFunctionError, fn -> run_test(mod, "sensitivity of ok") end
      assert error.module == AshQuint.Test.NoRepo
    end

    test "sandbox: compile errors" do
      for extra <- ["true", ~s("MyApp.Repo"), "[MyApp.Repo]", "@repo"] do
        error =
          assert_raise CompileError, fn ->
            compile(:ok, "use ExUnit.Case, register: false", ", sandbox: #{extra}")
          end

        assert error.description == "sandbox must be a repo module, got #{extra}"
      end
    end
  end

  describe "concurrent traces" do
    # Compiles a test module for `model` with `adapter` and extra options
    # given as source.
    defp compile_with(model, adapter, extra) do
      mod = Module.concat(__MODULE__, "Gen#{System.unique_integer([:positive])}")

      Code.compile_string("""
      defmodule #{inspect(mod)} do
        use ExUnit.Case, register: false

        use AshQuint.Case,
          config: #{inspect(@config)},
          model: #{inspect(model)},
          adapter: #{inspect(adapter)}#{extra}
      end
      """)

      mod
    end

    defp compile_with_error(model, extra) do
      error =
        assert_raise CompileError, fn -> compile_with(model, ConcurrentToyAdapter, extra) end

      error.description
    end

    test "concurrent traces are tagged quint_concurrent: true" do
      mod = compile_with(:concurrent, ConcurrentToyAdapter, "")
      tests = tests(mod)

      assert %{quint: :scenario, quint_model: :concurrent, quint_concurrent: true} =
               tests[:"test scenario overlapTest"]

      refute Map.has_key?(tests[:"test random 0"], :quint_concurrent)
      refute Map.has_key?(tests[:"test traces for concurrent are current"], :quint_concurrent)
      assert run_test(mod, "scenario overlapTest") == :ok
      assert run_test(mod, "random 0") == :ok
    end

    test "traces: :sequential defines only sequential replays" do
      sequential = tests(compile_with(:concurrent, ConcurrentToyAdapter, ", traces: :sequential"))

      assert Enum.sort(Map.keys(sequential)) == [
               :"test random 0",
               :"test traces for concurrent are current"
             ]

      concurrent = tests(compile_with(:concurrent, ConcurrentToyAdapter, ", traces: :concurrent"))

      assert Enum.sort(Map.keys(concurrent)) == [
               :"test scenario overlapTest",
               :"test traces for concurrent are current"
             ]

      all = tests(compile_with(:concurrent, ConcurrentToyAdapter, ", traces: :all"))
      assert map_size(all) == 3
    end

    test "sensitivity runs over the selected traces" do
      # The sequential trace alone has no starts, so no interleaving target.
      mod =
        compile_with(
          :concurrent,
          ConcurrentToyAdapterBlind,
          ", traces: :sequential, sensitivity: true"
        )

      assert run_test(mod, "sensitivity of concurrent") == :ok

      mod =
        compile_with(
          :concurrent,
          ConcurrentToyAdapterBlind,
          ", traces: :concurrent, sensitivity: true"
        )

      error =
        assert_raise ExUnit.AssertionError, fn -> run_test(mod, "sensitivity of concurrent") end

      assert error.message ==
               "sensitivity of :concurrent:\nserializing IncStart is never detected"
    end

    test "traces: :concurrent with no concurrent traces is a compile error" do
      assert compile_with_error(:ok, ", traces: :concurrent") ==
               "traces: :concurrent selects no trace of :ok; " <>
                 "test/fixtures/case/ok/manifest.json has no concurrent traces"
    end

    test "an invalid traces: is a compile error" do
      assert compile_with_error(:ok, ", traces: :some") ==
               "traces must be :all, :sequential or :concurrent, got :some"
    end

    test "allow_untested interleavings: accepts ~w and lists, and a stale entry fails" do
      for allowed <- [~s(["IncStart"]), "~w(IncStart)"] do
        sensitivity = ", sensitivity: [allow_untested: [interleavings: #{allowed}]]"
        mod = compile_with(:concurrent, ConcurrentToyAdapterBlind, sensitivity)
        assert run_test(mod, "sensitivity of concurrent") == :ok
      end

      sensitivity = ~s(, sensitivity: [allow_untested: [interleavings: ["IncStart", "Nope"]]])
      mod = compile_with(:concurrent, ConcurrentToyAdapter, sensitivity)

      error =
        assert_raise ExUnit.AssertionError, fn -> run_test(mod, "sensitivity of concurrent") end

      assert error.message ==
               """
               sensitivity of :concurrent:
               interleaving "IncStart" is allowed untested but is tested; \
               remove it from allow_untested
               interleaving "Nope" is allowed untested but starts no op in any trace; \
               remove it from allow_untested\
               """
    end

    test "allow_untested interleavings: must be strings" do
      assert compile_with_error(:ok, ", sensitivity: [allow_untested: [interleavings: [:a]]]") ==
               "allow_untested interleavings must be a literal list of strings or a ~w sigil, " <>
                 "got [:a]"
    end

    test "replay: options reach Replay.run!/3" do
      mod = compile_with(:concurrent, ConcurrentToyAdapter, ", replay: [gate_timeout: 0]")
      error = assert_raise ExUnit.AssertionError, fn -> run_test(mod, "scenario overlapTest") end
      assert error.message =~ "gate :requested of op \"o1\" was not released within 0ms"

      mod =
        compile_with(
          :concurrent,
          ConcurrentToyAdapter,
          ", replay: [settle_timeout: 100, step_timeout: 200, complete_timeout: 300, " <>
            "gate_timeout: 400]"
        )

      assert run_test(mod, "scenario overlapTest") == :ok
    end

    test "unknown replay: key is a compile error" do
      assert compile_with_error(:ok, ", replay: [settle: 10]") ==
               "unknown replay option :settle; expected settle_timeout, step_timeout, " <>
                 "complete_timeout or gate_timeout"

      assert compile_with_error(:ok, ", replay: 10") ==
               "replay must be a keyword list of settle_timeout, step_timeout, " <>
                 "complete_timeout and gate_timeout, got 10"

      assert compile_with_error(:ok, ", replay: [gate_timeout: -1]") ==
               "replay option gate_timeout must be a non-negative integer, got -1"
    end
  end

  describe "adapter check" do
    # Compiles a test module for `model` with `adapter` from a file named
    # `file`; returns the module and what went to stderr.
    defp compile_checked(model, adapter, file) do
      mod = Module.concat(__MODULE__, "Gen#{System.unique_integer([:positive])}")

      source = """
      defmodule #{inspect(mod)} do
        use ExUnit.Case, register: false

        use AshQuint.Case,
          config: #{inspect(@config)},
          model: #{inspect(model)},
          adapter: #{inspect(adapter)}
      end
      """

      {_result, stderr} =
        ExUnit.CaptureIO.with_io(:stderr, fn -> Code.compile_string(source, file) end)

      {mod, stderr}
    end

    test "a case module warns about an unknown action" do
      {_mod, stderr} =
        compile_checked(:promoted, AshQuint.Test.AdapterCheck.Typo, "test/check_typo_test.exs")

      assert stderr =~
               ~s(AshQuint.Test.AdapterCheck.Typo has a step/2 clause for "Incr", ) <>
                 "which isn't an action of :promoted (actions: Inc, Reset)"

      assert stderr =~
               ~s(AshQuint.Test.AdapterCheck.Typo step/2 clause for "Inc" matches pick "ctr", ) <>
                 "which Inc doesn't have (picks: by)"

      assert stderr =~ "test/check_typo_test.exs:4"
    end

    test "no check with a format 2 manifest" do
      {mod, stderr} =
        compile_checked(:concurrent, AshQuint.Test.AdapterCheck.Typo, "test/check_v2_test.exs")

      refute stderr =~ "step/2 clause"
      assert Map.has_key?(tests(mod), :"test traces for concurrent are current")
    end

    test "no check for an adapter without debug info" do
      adapter = Module.concat(__MODULE__, "InMemory#{System.unique_integer([:positive])}")

      Code.compile_string("""
      defmodule #{inspect(adapter)} do
        def step(ctx, %AshQuint.Step{action_taken: "Incr"}), do: ctx
      end
      """)

      {_mod, stderr} = compile_checked(:promoted, adapter, "test/check_memory_test.exs")
      refute stderr =~ "step/2 clause"
    end

    test "the toy adapter warns about the actions the promoted model doesn't have" do
      {_mod, stderr} = compile_checked(:promoted, ToyAdapter, "test/check_toy_test.exs")

      for action <- ~w(Peek Begin Commit) do
        assert stderr =~
                 ~s(AshQuint.Test.ToyAdapter has a step/2 clause for "#{action}", ) <>
                   "which isn't an action of :promoted (actions: Inc, Reset)"
      end
    end
  end
end
