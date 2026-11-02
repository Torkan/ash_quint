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
      `"witness witA"`, `"scenario incTest"`) and tagged `quint: <source>`
      and `quint_model: <model>`, which replays the trace with
      `AshQuint.Replay.run!/3`;
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
  trace of the manifest. It fails when a mutant survives, or when a key or
  an action is untested and isn't allow-listed. An allow-listed key or
  action that is tested, or that the check doesn't know, fails too, so the
  list can't go stale.

  The config, the manifest, every trace and every model file that exists
  are external resources, so the module recompiles when they change.

  An unknown model, a missing manifest or one without traces is a compile
  error.

  ## Options

    * `:model` (required) — the model's key in `ash_quint.exs`.
    * `:adapter` (required) — the `AshQuint.Adapter` module.
    * `:adapter_opts` — passed to the adapter's `init/2`. Default `[]`.
    * `:config` — the config file, relative to the project root. Default
      `"ash_quint.exs"`.
    * `:sensitivity` — `true`, or
      `[allow_untested: [keys: ["plans"], actions: ["Refresh"]]]` to accept
      the listed keys and actions as untested (deliberate constants, say).
      `true` is `[allow_untested: []]`. Default `false`.
  """

  alias AshQuint.{Config, Manifest, Sensitivity, Trace}

  @doc false
  defmacro __using__(opts) do
    env = __CALLER__
    model = required!(opts, :model, env)
    adapter = required!(opts, :adapter, env)

    allow_untested = sensitivity!(Keyword.get(opts, :sensitivity, false), env)
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

    manifest = read_manifest!(model_config, config.root, env)

    define(%{
      model: model,
      adapter: adapter,
      adapter_opts: Keyword.get(opts, :adapter_opts, []),
      config: model_config,
      root: config.root,
      config_file: Path.expand(config_path, config.root),
      manifest: manifest,
      allow_untested: allow_untested
    })
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

      {key, _value} when is_atom(key) ->
        compile_error!(
          env,
          "unknown allow_untested option #{inspect(key)}; expected keys or actions"
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
      "allow_untested must be a keyword list of keys and actions, got #{Macro.to_string(other)}"
    )
  end

  defp strings!(list, name, env) do
    if is_list(list) and Enum.all?(list, &is_binary/1) do
      list
    else
      compile_error!(
        env,
        "allow_untested #{name} must be a list of strings, got #{Macro.to_string(list)}"
      )
    end
  end

  defp required!(opts, key, env) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> compile_error!(env, "use AshQuint.Case needs the #{inspect(key)} option")
    end
  end

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
    replay_opts = [
      model: model,
      action_path: config.action_path,
      result_path: config.result_path,
      init_action: config.init_action,
      adapter_opts: setup.adapter_opts
    ]

    # Each trace's path and its Trace.load!/2 options.
    traces =
      for entry <- manifest.traces,
          do:
            {Path.join(out, entry.file),
             [name: entry.name, source: entry.source, seed: manifest.seed]}

    resources =
      [setup.config_file, Path.join(out, "manifest.json")] ++
        Enum.map(traces, &elem(&1, 0)) ++
        for({path, _hash} <- models -- missing, do: Path.join(root, path))

    trace_tests =
      for {path, trace_opts} <- traces do
        source = Keyword.fetch!(trace_opts, :source)

        quote do
          @tag quint: unquote(source), quint_model: unquote(model)
          ExUnit.Case.test unquote(Trace.label(Map.new(trace_opts))) do
            AshQuint.Replay.run!(
              unquote(setup.adapter),
              AshQuint.Trace.load!(unquote(path), unquote(trace_opts)),
              unquote(replay_opts)
            )
          end
        end
      end

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

  defp stale_reason(target, result) do
    case {target in result.tested, target} do
      {true, _target} -> "is tested"
      {false, {:key, _key}} -> "isn't in any projection"
      {false, {:call, _action}} -> "makes no system call in any trace"
    end
  end

  @spec compile_error!(Macro.Env.t(), String.t()) :: no_return()
  defp compile_error!(env, description) do
    raise CompileError, file: env.file, line: env.line, description: description
  end
end
