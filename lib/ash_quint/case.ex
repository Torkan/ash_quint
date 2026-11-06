defmodule AshQuint.Case do
  @moduledoc """
  Defines one ExUnit test per committed trace of a model.

      defmodule MyApp.TemporalTraceTest do
        use MyApp.DataCase, async: true

        use AshQuint.Case,
          model: :temporal,
          adapter: MyApp.TemporalTrace
      end

  Use it after `ExUnit.Case`, or after the project's case template that uses
  it, so the template's setup (a database sandbox, say) and `async` apply.

  At compile time it reads `ash_quint.exs` and the model's manifest
  (`<out>/manifest.json`) and defines:

    * a test per trace, named `"<source> <name>"` (`"random 7"`,
      `"witness witA"`, `"scenario incTest"`, `"regression 4031_2"`) and
      tagged `quint: <source>` and `quint_model: <model>` (and
      `quint_concurrent: true` when the manifest marks the trace
      concurrent), which replays the trace with `AshQuint.Replay.run!/3`,
      with the manifest's seed, or a regression entry's own seed (the
      seed it was found with; see `mix ash_quint.promote`). Its failure
      message ends with `trace: <path>`, the trace file from the project
      root, and, for a regression trace with provenance, `quint: <command>`,
      the `quint run` that regenerates it (`AshQuint.Gen.quint_line/2`),
      then, for a shrunk one, `run: <expression>`, the Quint run of its
      steps (see `AshQuint.Shrink`);
    * `"traces for <model> are current"`, tagged `quint_model: <model>`,
      which fails when a model file's hash differs from the manifest's, so
      the traces need regenerating with `mix ash_quint.gen`.

  A model file that is missing fails the staleness test, unless the model
  has `on_missing_model: :skip` (for projects that don't commit their
  models); then the test is tagged `skip:` when the file is missing at
  compile time, and not checked when it is missing at test time. The
  replays run either way, since they need only the committed traces.

  With `sensitivity:`, it also defines `"sensitivity of <model>"`, tagged
  `quint_model: <model>`, which runs `AshQuint.Sensitivity.check/3` on every
  selected trace. It fails when a mutant survives, or when a key, an action
  or an interleaving is untested and isn't allow-listed. An allow-listed
  target that is tested, or that the check doesn't know, fails too, so the
  list can't go stale.

  Concurrent traces run their ops in other processes, which a private ETS
  table or a database sandbox may not allow. `traces:` splits one model's
  traces between two modules: the sequential ones in an async module, the
  concurrent ones in an `async: false` module against an unboxed database,
  say:

      defmodule MyApp.RaceTraceTest do
        use MyApp.DataCase, async: true
        use AshQuint.Case, model: :race, adapter: MyApp.RaceTrace, traces: :sequential
      end

      defmodule MyApp.RaceConcurrentTraceTest do
        use MyApp.UnboxedCase, async: false

        use AshQuint.Case,
          model: :race,
          adapter: MyApp.RaceTrace,
          traces: :concurrent,
          sensitivity: true
      end

  Each module also defines the staleness test (and, with `sensitivity:`,
  its own sensitivity test over its traces).

  With `explore:`, it also defines `"explore <model>"`, tagged
  `quint_explore: <model>` and `timeout: :infinity` (not `quint_model:`, so
  selecting a model's tests by that tag leaves it out),
  which runs `AshQuint.Explore.run!/2`: it replays fresh `quint run`
  traces of the model's `random:` source with the module's adapter,
  `adapter_opts`, `replay` options and `traces:` selection, and fails
  listing each failure as a candidate regression trace. Exclude it from
  the suite in `test/test_helper.exs`
  (`ExUnit.start(exclude: [:quint_explore])`) and run it with
  `mix ash_quint.explore`; run any other way, it fails at once.

  The config, the manifest, every trace and every model file that exists
  are external resources, so the module recompiles when they change.

  An unknown model, a missing manifest or one without traces is a compile
  error.

  With a format 3 manifest, it checks the adapter's `step/2` clauses
  against the model interface (`AshQuint.Interface`), read from the
  compiled adapter's debug info, and warns (`IO.warn/2`, at the `use`
  line) about a clause for an action the model doesn't have, a clause
  matching a pick its action doesn't have (map picks aren't checked), and
  an action without a clause (never the init action, and not when a
  clause has no literal `action_taken`, as a delegating
  `def step(ctx, step)` does). A clause's literal action and picks are
  read from a `%AshQuint.Step{}` or plain map pattern. An adapter without
  debug info, or that doesn't define `step/2`, isn't checked.
  `mix test --warnings-as-errors` turns the warnings into failures.

  ## Options

    * `:model` (required) — the model's key in `ash_quint.exs`.
    * `:adapter` (required) — the `AshQuint.Adapter` module.
    * `:adapter_opts` — passed to the adapter's `init/2`. Default `[]`.
    * `:config` — the config file, relative to the project root. Default
      `"ash_quint.exs"`.
    * `:sensitivity` — `true`, or
      `[allow_untested: [keys: ["plans"], actions: ["Refresh"]]]` to accept
      the listed keys and actions as untested (deliberate constants, say).
      The lists must be literal lists of strings or `~w` sigils: they're read
      at compile time, so module attributes and variables aren't allowed.
      `true` is `[allow_untested: []]`. Default `false`. `interleavings:`
      lists start actions whose serialization may go undetected, or whose
      ops never overlap (`[allow_untested: [interleavings: ["IncStart"]]]`).
      `vars:` lists model variables the projection deliberately leaves out,
      such as in-flight bookkeeping
      (`[allow_untested: [vars: ~w(inflight finished)]]`); see
      `AshQuint.Sensitivity`.
    * `:traces` — which of the manifest's traces get a test and go into
      the sensitivity check: `:all`, `:sequential` (those the manifest
      doesn't mark concurrent) or `:concurrent`. A selection with no trace
      is a compile error. Default `:all`.
    * `:explore` — `true`, or `[max_steps: 20, batch: 25]`: defines the
      explore test. `max_steps` is the length of the fresh traces (default
      the model's `random:` `max_steps`, else Quint's), `batch` the traces
      per `quint run` (default 20); both must be literal positive
      integers. `true` is `[]`. The model needs `random:`. Default `false`.
    * `:replay` — `AshQuint.Replay.run/3` timeouts, in ms:
      `[settle_timeout: …, step_timeout: …, complete_timeout: …,
      gate_timeout: …]`. Any other key is a compile error. Default `[]`
      (the replay's defaults).
  """

  alias AshQuint.Case.AdapterCheck
  alias AshQuint.{Config, Gen, Interface, Manifest, Sensitivity, Trace}
  alias AshQuint.Config.Model

  @doc false
  defmacro __using__(opts) do
    env = __CALLER__
    model = required!(opts, :model, env)
    adapter = required!(opts, :adapter, env)

    allow_untested = sensitivity!(Keyword.get(opts, :sensitivity, false), env)
    selection = traces!(Keyword.get(opts, :traces, :all), env)
    replay = replay!(Keyword.get(opts, :replay, []), env)
    explore = explore!(Keyword.get(opts, :explore, false), env)
    config_path = Keyword.get(opts, :config, "ash_quint.exs")

    config =
      try do
        Config.load!(config_path)
      rescue
        error in Mix.Error -> compile_error!(env, error.message)
      end

    model_config =
      try do
        Config.model!(config, model)
      rescue
        error in Mix.Error -> compile_error!(env, error.message)
      end

    if explore != nil and model_config.random == nil do
      compile_error!(env, "explore needs random: for #{inspect(model)} in ash_quint.exs")
    end

    manifest = read_manifest!(model_config, config.root, env)
    check_adapter(adapter, model_config, manifest, env)
    manifest = select!(manifest, selection, model_config, env)

    define(%{
      model: model,
      adapter: adapter,
      adapter_opts: Keyword.get(opts, :adapter_opts, []),
      config: model_config,
      project_config: config,
      root: config.root,
      config_file: Path.expand(config_path, config.root),
      manifest: manifest,
      allow_untested: allow_untested,
      replay: replay,
      explore: explore,
      config_path: config_path,
      selection: selection
    })
  end

  @selections [:all, :sequential, :concurrent]

  defp traces!(selection, _env) when selection in @selections, do: selection

  defp traces!(other, env) do
    compile_error!(
      env,
      "traces must be :all, :sequential or :concurrent, got #{Macro.to_string(other)}"
    )
  end

  # Keeps the manifest entries `selection` picks; none is a compile error.
  defp select!(manifest, :all, _model_config, _env), do: manifest

  defp select!(manifest, selection, model_config, env) do
    concurrent = selection == :concurrent

    case Enum.filter(manifest.traces, &(&1.concurrent == concurrent)) do
      [] ->
        compile_error!(
          env,
          "traces: #{inspect(selection)} selects no trace of #{inspect(model_config.name)}; " <>
            "#{Path.join(model_config.out, "manifest.json")} has no #{selection} traces"
        )

      traces ->
        %{manifest | traces: traces}
    end
  end

  @replay_keys [:settle_timeout, :step_timeout, :complete_timeout, :gate_timeout]
  @replay_shape "settle_timeout, step_timeout, complete_timeout and gate_timeout"

  # The replay: options, as the caller's AST (a value may be an
  # expression); a literal value must be a non-negative integer.
  defp replay!(opts, env) when is_list(opts) do
    Enum.map(opts, fn
      {key, value} when key in @replay_keys ->
        if literal?(value) and not (is_integer(value) and value >= 0) do
          compile_error!(
            env,
            "replay option #{key} must be a non-negative integer, got #{Macro.to_string(value)}"
          )
        end

        {key, value}

      {key, _value} when is_atom(key) ->
        compile_error!(
          env,
          "unknown replay option #{inspect(key)}; expected settle_timeout, step_timeout, " <>
            "complete_timeout or gate_timeout"
        )

      _other ->
        replay_error!(opts, env)
    end)
  end

  defp replay!(other, env), do: replay_error!(other, env)

  # -1 is quoted as a call of -/1.
  defp literal?({:-, _meta, [number]}) when is_number(number), do: true
  defp literal?(value), do: Macro.quoted_literal?(value)

  @spec replay_error!(term(), Macro.Env.t()) :: no_return()
  defp replay_error!(other, env) do
    compile_error!(
      env,
      "replay must be a keyword list of #{@replay_shape}, got #{Macro.to_string(other)}"
    )
  end

  @explore_keys [:max_steps, :batch]
  @explore_shape "true, false or a keyword list of max_steps and batch"

  # nil (no explore test) or the explore options; values must be literal
  # positive integers.
  defp explore!(false, _env), do: nil
  defp explore!(true, _env), do: []

  defp explore!(opts, env) when is_list(opts) do
    Enum.map(opts, fn
      {key, value} when key in @explore_keys ->
        unless is_integer(value) and value > 0 do
          compile_error!(
            env,
            "explore option #{key} must be a positive integer, got #{Macro.to_string(value)}"
          )
        end

        {key, value}

      {key, _value} when is_atom(key) ->
        compile_error!(
          env,
          "unknown explore option #{inspect(key)}; expected max_steps or batch"
        )

      _other ->
        explore_error!(opts, env)
    end)
  end

  defp explore!(other, env), do: explore_error!(other, env)

  @spec explore_error!(term(), Macro.Env.t()) :: no_return()
  defp explore_error!(other, env) do
    compile_error!(env, "explore must be #{@explore_shape}, got #{Macro.to_string(other)}")
  end

  @sensitivity_shape "true, false or [allow_untested: [keys: [...], actions: [...]]]"

  # nil (no sensitivity test) or the allow-listed targets.
  defp sensitivity!(false, _env), do: nil
  defp sensitivity!(true, _env), do: []

  defp sensitivity!(opts, env) when is_list(opts) do
    Enum.flat_map(opts, fn
      {:allow_untested, allow} ->
        allow_untested!(allow, env)

      {key, _value} when is_atom(key) ->
        compile_error!(env, "unknown sensitivity option #{inspect(key)}; expected allow_untested")

      _other ->
        sensitivity_error!(opts, env)
    end)
  end

  defp sensitivity!(other, env), do: sensitivity_error!(other, env)

  @spec sensitivity_error!(term(), Macro.Env.t()) :: no_return()
  defp sensitivity_error!(other, env) do
    compile_error!(
      env,
      "sensitivity must be #{@sensitivity_shape}, got #{Macro.to_string(other)}"
    )
  end

  defp allow_untested!(allow, env) when is_list(allow) do
    Enum.flat_map(allow, fn
      {:keys, keys} ->
        Enum.map(strings!(keys, "keys", env), &{:key, &1})

      {:actions, actions} ->
        Enum.map(strings!(actions, "actions", env), &{:call, &1})

      {:interleavings, actions} ->
        Enum.map(strings!(actions, "interleavings", env), &{:interleaving, &1})

      {:vars, vars} ->
        Enum.map(strings!(vars, "vars", env), &{:var, &1})

      {key, _value} when is_atom(key) ->
        compile_error!(
          env,
          "unknown allow_untested option #{inspect(key)}; " <>
            "expected keys, actions, interleavings or vars"
        )

      _other ->
        allow_untested_error!(allow, env)
    end)
  end

  defp allow_untested!(other, env), do: allow_untested_error!(other, env)

  @spec allow_untested_error!(term(), Macro.Env.t()) :: no_return()
  defp allow_untested_error!(other, env) do
    compile_error!(
      env,
      "allow_untested must be a keyword list of keys, actions, interleavings and vars, " <>
        "got #{Macro.to_string(other)}"
    )
  end

  # The options arrive unexpanded, so a ~w or ~W sigil is still a call. Without
  # interpolation, expanding it gives a literal list.
  defp strings!(list, name, env) do
    case expand_sigil(list, env) do
      strings when is_list(strings) ->
        if Enum.all?(strings, &is_binary/1), do: strings, else: strings_error!(list, name, env)

      _other ->
        strings_error!(list, name, env)
    end
  end

  defp expand_sigil({sigil, _meta, [_string, _modifiers]} = ast, env)
       when sigil in [:sigil_w, :sigil_W],
       do: Macro.expand(ast, env)

  defp expand_sigil(other, _env), do: other

  @spec strings_error!(term(), String.t(), Macro.Env.t()) :: no_return()
  defp strings_error!(list, name, env) do
    compile_error!(
      env,
      "allow_untested #{name} must be a literal list of strings or a ~w sigil, " <>
        "got #{Macro.to_string(list)}"
    )
  end

  defp required!(opts, key, env) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> compile_error!(env, "use AshQuint.Case needs the #{inspect(key)} option")
    end
  end

  # Warns about the adapter's step/2 clauses that the model interface
  # doesn't match (format 3 manifests, compiled adapters with debug info).
  defp check_adapter(adapter, model_config, %Manifest{interface: %Interface{} = interface}, env) do
    adapter = Macro.expand(adapter, env)

    with true <- is_atom(adapter),
         {:module, adapter} <- Code.ensure_compiled(adapter) do
      adapter
      |> AdapterCheck.warnings(model_config.name, interface, model_config.init_action)
      |> Enum.each(&IO.warn(&1, Macro.Env.stacktrace(env)))
    end

    :ok
  end

  defp check_adapter(_adapter, _model_config, _manifest, _env), do: :ok

  defp read_manifest!(model_config, root, env) do
    name = model_config.name
    path = Path.join(model_config.out, "manifest.json")

    manifest =
      try do
        Manifest.read!(Path.join(root, path))
      rescue
        File.Error ->
          compile_error!(
            env,
            "no manifest for #{inspect(name)} at #{path}; run mix ash_quint.gen #{name}"
          )
      end

    if manifest.traces == [] do
      compile_error!(
        env,
        "manifest for #{inspect(name)} at #{path} has no traces; run mix ash_quint.gen #{name}"
      )
    end

    manifest
  end

  defp define(%{config: config, root: root, manifest: manifest} = setup) do
    model = setup.model
    out = Path.join(root, config.out)
    models = Enum.sort(manifest.models)
    missing = Enum.reject(models, fn {path, _hash} -> File.regular?(Path.join(root, path)) end)

    # adapter_opts is the caller's AST, spliced in as is.
    replay_opts =
      Model.replay_opts(config) ++ [adapter_opts: setup.adapter_opts] ++ setup.replay

    # Each trace's path and its Trace.load!/2 options.
    traces = Enum.map(manifest.traces, &trace(&1, out, manifest.seed))

    resources =
      [setup.config_file, Path.join(out, "manifest.json")] ++
        Enum.map(traces, &elem(&1, 0)) ++
        for({path, _hash} <- models -- missing, do: Path.join(root, path))

    trace_tests =
      Enum.map(manifest.traces, &trace_test(&1, out, setup, replay_opts))

    sensitivity_test =
      if setup.allow_untested do
        quote do
          @tag quint_model: unquote(model)
          ExUnit.Case.test unquote("sensitivity of #{model}") do
            AshQuint.Case.__check_sensitivity__(
              unquote(model),
              unquote(setup.adapter),
              unquote(traces),
              unquote(replay_opts),
              unquote(setup.allow_untested)
            )
          end
        end
      end

    explore_test = if setup.explore, do: explore_test(setup)

    skip =
      case {config.on_missing_model, missing} do
        {:skip, [{path, _hash} | _]} -> "model file #{path} for #{inspect(model)} is missing"
        _other -> nil
      end

    quote do
      # ExUnit.Case registers its attributes when the module body runs, after
      # every macro in it has expanded, so this check runs there too.
      AshQuint.Case.__require_ex_unit__(__ENV__)

      require ExUnit.Case

      for resource <- unquote(resources), do: @external_resource(resource)

      unquote_splicing(trace_tests)

      unquote(sensitivity_test)

      unquote(explore_test)

      if unquote(skip), do: @tag(skip: unquote(skip))
      @tag quint_model: unquote(model)
      ExUnit.Case.test unquote("traces for #{model} are current") do
        AshQuint.Case.__check_current__(
          unquote(model),
          unquote(root),
          unquote(models),
          unquote(config.on_missing_model)
        )
      end
    end
  end

  defp explore_test(setup) do
    model = setup.model

    # adapter_opts and the replay values are the caller's AST, spliced in.
    opts =
      [
        model: model,
        adapter: setup.adapter,
        config: setup.config_path,
        adapter_opts: setup.adapter_opts,
        replay: setup.replay,
        traces: setup.selection
      ] ++ setup.explore

    quote do
      # Not quint_model:, so `mix test --only quint_model:<model>` leaves it out.
      @tag quint_explore: unquote(model), timeout: :infinity
      ExUnit.Case.test unquote("explore #{model}") do
        AshQuint.Explore.run!(unquote(opts))
      end
    end
  end

  # A regression entry carries the seed it was found with.
  defp trace(entry, out, seed) do
    seed = Map.get(entry, :seed, seed)
    {Path.join(out, entry.file), [name: entry.name, source: entry.source, seed: seed]}
  end

  defp trace_test(entry, out, setup, replay_opts) do
    {path, trace_opts} = trace(entry, out, setup.manifest.seed)
    replay_opts = replay_opts ++ [context: context(entry, path, setup)]
    tags = [quint: entry.source, quint_model: setup.model]
    tags = if entry.concurrent, do: tags ++ [quint_concurrent: true], else: tags

    quote do
      @tag unquote(tags)
      ExUnit.Case.test unquote(Trace.label(Map.new(trace_opts))) do
        AshQuint.Replay.run!(
          unquote(setup.adapter),
          AshQuint.Trace.load!(unquote(path), unquote(trace_opts)),
          unquote(replay_opts)
        )
      end
    end
  end

  # A trace test's failure ends with the trace's path, and for a regression
  # trace with provenance the command that regenerates it and, when it was
  # shrunk, its run.
  defp context(entry, path, setup) do
    trace_line = "trace: " <> Path.join(setup.config.out, entry.file)

    with :regression <- entry.source,
         {:ok, binary} <- File.read(path),
         {:ok, provenance} <- Gen.provenance(binary),
         line when is_binary(line) <- Gen.quint_line(setup.project_config, provenance) do
      [trace_line, "quint: " <> line] ++ run_line(provenance)
    else
      _none -> [trace_line]
    end
  end

  defp run_line(%{"shrunk" => %{"run" => run}}) when is_binary(run), do: ["run:   " <> run]
  defp run_line(_provenance), do: []

  @doc false
  @spec __require_ex_unit__(Macro.Env.t()) :: :ok
  def __require_ex_unit__(env) do
    if Module.has_attribute?(env.module, :ex_unit_tests) do
      :ok
    else
      compile_error!(
        env,
        "use ExUnit.Case (or a case template that uses it) before AshQuint.Case"
      )
    end
  end

  @doc false
  @spec __check_current__(
          atom(),
          String.t(),
          [{String.t(), String.t()}],
          Config.on_missing_model()
        ) ::
          :ok
  def __check_current__(model, root, models, on_missing_model) do
    Enum.each(models, fn {path, hash} ->
      file = Path.join(root, path)

      cond do
        not File.regular?(file) and on_missing_model == :skip ->
          :ok

        not File.regular?(file) ->
          ExUnit.Assertions.flunk(
            "model file #{path} for #{inspect(model)} is missing; " <>
              "set on_missing_model: :skip if models aren't committed"
          )

        Manifest.hash_file(file) != hash ->
          ExUnit.Assertions.flunk(
            "traces for #{inspect(model)} are stale: #{path} changed; " <>
              "run mix ash_quint.gen #{model}"
          )

        true ->
          :ok
      end
    end)
  end

  @doc false
  @spec __check_sensitivity__(
          atom(),
          module(),
          [{String.t(), keyword()}],
          [AshQuint.Replay.option()],
          [AshQuint.Sensitivity.target()]
        ) :: :ok
  def __check_sensitivity__(model, adapter, traces, replay_opts, allow_untested) do
    traces = Enum.map(traces, fn {path, opts} -> Trace.load!(path, opts) end)
    result = Sensitivity.check(adapter, traces, replay_opts)
    remaining = %{result | untested: result.untested -- allow_untested}

    stale =
      for target <- allow_untested, target not in result.untested do
        "#{describe(target)} is allowed untested but #{stale_reason(target, result)}; " <>
          "remove it from allow_untested"
      end

    case Enum.reject([Sensitivity.format(remaining) | stale], &(&1 == "")) do
      [] ->
        :ok

      lines ->
        ExUnit.Assertions.flunk("sensitivity of #{inspect(model)}:\n" <> Enum.join(lines, "\n"))
    end
  end

  defp describe({:key, key}), do: "key #{inspect(key)}"
  defp describe({:call, action}), do: "action #{inspect(action)}"
  defp describe({:interleaving, action}), do: "interleaving #{inspect(action)}"
  defp describe({:var, var}), do: "variable #{inspect(var)}"

  defp stale_reason(target, result) do
    case {target in result.tested, target} do
      {true, {:var, _var}} -> "is projected"
      {true, _target} -> "is tested"
      {false, {:key, _key}} -> "isn't in any projection"
      {false, {:call, _action}} -> "makes no system call in any trace"
      {false, {:interleaving, _action}} -> "starts no op in any trace"
      {false, {:var, _var}} -> "isn't a model variable"
    end
  end

  @spec compile_error!(Macro.Env.t(), String.t()) :: no_return()
  defp compile_error!(env, description) do
    raise CompileError, file: env.file, line: env.line, description: description
  end
end
