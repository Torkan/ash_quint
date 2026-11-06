defmodule AshQuint.Config do
  @moduledoc """
  Loads and validates `ash_quint.exs`.

  The file evaluates to a keyword list:

      [
        quint: "0.33.1",                                  # required
        quint_cmd: ["npx", "--yes", "@informalsystems/quint@{version}"],
        model_dir: "test/quint",
        fixture_dir: "test/fixtures/quint",
        on_missing_model: :fail,                          # or :skip
        backend: "rust",                                  # or "typescript"; default: unset
        models: [
          counter: [
            model: "test/quint/counter/model.qnt",        # default: <model_dir>/<name>/model.qnt
            tests: "test/quint/counter/model-tests.qnt",  # default: <model_dir>/<name>/model-tests.qnt
            out: "test/fixtures/quint/counter",           # default: <fixture_dir>/<name>
            on_missing_model: :fail,                      # default: the top-level setting
            backend: "rust",                              # default: the top-level setting
            seed: 1,                                      # required
            action_path: ["lastAction"],
            result_path: ["lastResult"],
            pending_result: "Pending",                    # see AshQuint.Step
            op_field: "op",
            init_action: "Init",
            random: [main: "counter", n_traces: 20, max_steps: 12, max_samples: 200],
            # random and witnesses also take init: and step:, the model's
            # init and step actions when they aren't named init and step
            witnesses: [main: "counter", names: ["witA"], max_steps: 12, max_samples: 50_000],
            scenarios: [main: "tests", match: "Test$"],
            shrink: true                                  # or [apply: "apply", rounds: 20]
          ]
        ]
      ]

  `backend` is the Quint simulator backend, passed as `--backend` to every
  `quint run` and `quint test`; unset, Quint picks its own default. Each
  `main` is the name of a Quint module: the model's for `random` and
  `witnesses`, the tests file's for `scenarios`. `shrink` turns on the
  shrinking of explore candidates (see `AshQuint.Shrink`): `true`, or a
  keyword list with `apply` (the name of a model action taking the action
  value, called in place of each action's operator), `import` (what the
  shrink wrapper imports from the model file: by default `random`'s
  `main`, or an instance like `"counter(CAP = 5)"` when `main` is an
  instance module) and `rounds` (the budget of rounds, default 20);
  `false` or unset is off. Each model needs at least one of `random`,
  `witnesses` and `scenarios`. Unknown and duplicate keys
  are errors. Paths, the defaults built from a model's name included, must
  be relative to the project root and stay inside it; they are kept exactly
  as configured. Each model's `out` must be its own directory, not the
  project root and not another model's `out`. Every error is a `Mix.Error`
  naming the key.
  """

  alias AshQuint.Config.Model

  @enforce_keys [:quint, :root, :models]
  defstruct quint: nil,
            quint_cmd: ["npx", "--yes", "@informalsystems/quint@{version}"],
            model_dir: "test/quint",
            fixture_dir: "test/fixtures/quint",
            on_missing_model: :fail,
            backend: nil,
            root: nil,
            models: %{}

  @type on_missing_model :: :fail | :skip

  @type backend :: String.t()

  @type t :: %__MODULE__{
          quint: String.t(),
          quint_cmd: [String.t()],
          model_dir: String.t(),
          fixture_dir: String.t(),
          on_missing_model: on_missing_model(),
          backend: backend() | nil,
          root: String.t(),
          models: %{atom() => Model.t()}
        }

  @top_keys [
    quint: :string,
    quint_cmd: :strings,
    model_dir: :path,
    fixture_dir: :path,
    on_missing_model: :on_missing_model,
    backend: :backend,
    models: :models
  ]

  @model_keys [
    model: :path,
    tests: :path,
    out: :path,
    on_missing_model: :on_missing_model,
    backend: :backend,
    seed: :integer,
    action_path: :strings,
    result_path: :strings,
    pending_result: :pending_result,
    op_field: :string,
    init_action: :string,
    random: :random,
    witnesses: :witnesses,
    scenarios: :scenarios,
    shrink: :shrink
  ]

  @shrink_keys [apply: :quint_name, import: :quint_instance, rounds: :pos_integer]

  @quint_name ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  # A module name, optionally with its instance's overrides: `counter(CAP = 5)`.
  @quint_instance ~r/\A[A-Za-z_][A-Za-z0-9_]*(\s*\(.*\))?\z/s

  @source_keys %{
    random: [
      main: :string,
      init: :string,
      step: :string,
      n_traces: :pos_integer,
      max_steps: :pos_integer,
      max_samples: :pos_integer
    ],
    witnesses: [
      main: :string,
      init: :string,
      step: :string,
      names: :strings,
      max_steps: :pos_integer,
      max_samples: :pos_integer
    ],
    scenarios: [main: :string, match: :string]
  }

  @source_required %{random: [:main], witnesses: [:main, :names], scenarios: [:main]}

  @sources [:random, :witnesses, :scenarios]

  @doc """
  Reads `path` (relative to `opts[:root]`, default `File.cwd!()`) and
  validates it with `validate!/2`.
  """
  @spec load!(Path.t(), keyword()) :: t()
  def load!(path \\ "ash_quint.exs", opts \\ []) do
    root = Keyword.get_lazy(opts, :root, &File.cwd!/0)
    file = Path.expand(path, root)

    unless File.regular?(file), do: Mix.raise("ash_quint.exs not found at #{file}")

    {config, _binding} = Code.eval_file(file)
    validate!(config, root)
  end

  @doc """
  Validates an evaluated config and resolves every default. `root` is the
  project root that paths are checked against.
  """
  @spec validate!(term(), String.t()) :: t()
  def validate!(config, root) do
    check_keyword!(config, [], @top_keys)
    Enum.each([:quint, :models], &require_key!(config, [], &1))
    check_values!(config, [], @top_keys, root)

    top = struct!(__MODULE__, Keyword.put(config, :root, root))

    models = Enum.map(config[:models], fn {name, opts} -> model(name, opts, top, root) end)
    check_outs!(models, root)

    %{top | models: Map.new(models, &{&1.name, &1})}
  end

  @doc """
  Returns the configured model `name`, or raises a `Mix.Error`.
  """
  @spec model!(t(), atom()) :: Model.t()
  def model!(%__MODULE__{models: models}, name) do
    case Map.fetch(models, name) do
      {:ok, model} -> model
      :error -> Mix.raise("model #{inspect(name)} is not configured in ash_quint.exs")
    end
  end

  @doc """
  The models named in `names` (strings, as given on the command line), in
  that order, or every configured model sorted by name when `names` is
  empty. An unknown name raises a `Mix.Error`; no atoms are created.
  """
  @spec select!(t(), [String.t()]) :: [Model.t()]
  def select!(%__MODULE__{models: models}, []),
    do: models |> Map.values() |> Enum.sort_by(& &1.name)

  def select!(%__MODULE__{models: models}, names) do
    by_name = Map.new(models, fn {name, model} -> {Atom.to_string(name), model} end)

    Enum.map(names, fn name ->
      case Map.fetch(by_name, name) do
        {:ok, model} -> model
        :error -> Mix.raise("model :#{name} is not configured in ash_quint.exs")
      end
    end)
  end

  # A Quint identifier: a letter or underscore, then letters, digits and
  # underscores.
  @doc false
  @spec quint_name?(term()) :: boolean()
  def quint_name?(name), do: is_binary(name) and name =~ @quint_name

  @doc """
  The Quint command, with `{version}` replaced by the configured version in
  each element.
  """
  @spec quint_cmd(t()) :: [String.t()]
  def quint_cmd(%__MODULE__{quint_cmd: cmd, quint: version}) do
    Enum.map(cmd, &String.replace(&1, "{version}", version))
  end

  defp model(name, opts, top, root) do
    path = ["models", Atom.to_string(name)]
    check_keyword!(opts, path, @model_keys)
    require_key!(opts, path, :seed)

    unless Enum.any?(@sources, &Keyword.has_key?(opts, &1)) do
      fail!("#{join(path)} needs at least one of random, witnesses, scenarios")
    end

    check_values!(opts, path, @model_keys, root)
    dir = Atom.to_string(name)

    model =
      struct!(
        Model,
        [
          name: name,
          model: Path.join([top.model_dir, dir, "model.qnt"]),
          tests: Path.join([top.model_dir, dir, "model-tests.qnt"]),
          out: Path.join(top.fixture_dir, dir),
          on_missing_model: top.on_missing_model,
          backend: top.backend
        ] ++ Keyword.update(opts, :shrink, nil, &shrink/1)
      )

    # A default path joins the model name, which can contain `..`.
    Enum.each([:model, :tests, :out], &check!(:path, Map.fetch!(model, &1), path ++ [&1], root))
    model
  end

  # `shrink: true` is every default; `false` is off, like unset.
  defp shrink(true), do: []
  defp shrink(false), do: nil
  defp shrink(opts), do: opts

  # Two models writing one `out` would remove each other's traces, and an
  # `out` at the root would take over the project's own files.
  defp check_outs!(models, root) do
    Enum.reduce(models, %{}, fn model, seen ->
      out = Path.expand(model.out, root)
      key = "models.#{model.name}.out (#{model.out})"

      cond do
        out == Path.expand(root) ->
          fail!("#{key} is the project root")

        other = seen[out] ->
          fail!("#{key} is the same directory as models.#{other}.out")

        true ->
          Map.put(seen, out, model.name)
      end
    end)
  end

  defp check_keyword!(value, path, allowed) do
    unless is_list(value) and Keyword.keyword?(value) do
      fail!(prefixed(path, "must be a keyword list, got #{inspect(value)}"))
    end

    Enum.each(value, fn {key, _} ->
      unless Keyword.has_key?(allowed, key), do: fail!("unknown key #{key_name(path, key)}")
    end)

    value
    |> Keyword.keys()
    |> Enum.frequencies()
    |> Enum.each(fn {key, count} ->
      if count > 1, do: fail!("duplicate key #{key_name(path, key)}")
    end)
  end

  defp require_key!(keyword, path, key) do
    unless Keyword.has_key?(keyword, key), do: fail!("#{join(path ++ [key])} is required")
  end

  defp check_values!(keyword, path, spec, root) do
    Enum.each(keyword, fn {key, value} -> check!(spec[key], value, path ++ [key], root) end)
  end

  defp check!(:string, value, _path, _root) when is_binary(value), do: :ok
  defp check!(:string, value, path, _root), do: type_error!(path, "a string", value)

  defp check!(:quint_name, value, path, root) do
    check!(:string, value, path, root)
    unless quint_name?(value), do: type_error!(path, "a Quint name", value)
  end

  defp check!(:quint_instance, value, path, root) do
    check!(:string, value, path, root)

    unless value =~ @quint_instance do
      type_error!(path, ~s{a Quint module, or an instance like "counter(CAP = 5)"}, value)
    end
  end

  defp check!(:integer, value, _path, _root) when is_integer(value), do: :ok
  defp check!(:integer, value, path, _root), do: type_error!(path, "an integer", value)

  defp check!(:pos_integer, value, _path, _root) when is_integer(value) and value > 0, do: :ok

  defp check!(:pos_integer, value, path, _root),
    do: type_error!(path, "a positive integer", value)

  defp check!(:strings, value, path, _root) do
    unless strings?(value), do: type_error!(path, "a non-empty list of strings", value)
  end

  defp check!(:pending_result, value, path, _root) when value in ["Accepted", "Rejected"],
    do: fail!("#{join(path)} can't be #{value}, which is already a result")

  defp check!(:pending_result, value, path, root), do: check!(:string, value, path, root)

  defp check!(:on_missing_model, value, _path, _root) when value in [:fail, :skip], do: :ok

  defp check!(:on_missing_model, value, path, _root),
    do: type_error!(path, ":fail or :skip", value)

  defp check!(:backend, value, _path, _root) when value in ["rust", "typescript"], do: :ok

  defp check!(:backend, value, path, _root),
    do: type_error!(path, ~s("rust" or "typescript"), value)

  defp check!(:models, value, path, _root) do
    unless value != [] and is_list(value) and Keyword.keyword?(value) do
      type_error!(path, "a non-empty keyword list", value)
    end
  end

  defp check!(:path, value, path, root) do
    check!(:string, value, path, root)

    cond do
      Path.type(value) != :relative ->
        fail!("#{join(path)} must be relative to the project root")

      not inside?(value, root) ->
        fail!("#{join(path)} (#{value}) is outside the project")

      true ->
        :ok
    end
  end

  defp check!(:shrink, value, _path, _root) when is_boolean(value), do: :ok

  defp check!(:shrink, value, path, _root) do
    unless is_list(value) and Keyword.keyword?(value) do
      type_error!(path, "true or a keyword list", value)
    end

    check_keyword!(value, path, @shrink_keys)
    check_values!(value, path, @shrink_keys, nil)
  end

  defp check!(source, value, path, _root) when source in @sources do
    spec = Map.fetch!(@source_keys, source)
    check_keyword!(value, path, spec)
    Enum.each(Map.fetch!(@source_required, source), &require_key!(value, path, &1))
    check_values!(value, path, spec, nil)
  end

  defp strings?([_ | _] = list), do: Enum.all?(list, &is_binary/1)
  defp strings?(_value), do: false

  defp inside?(path, root) do
    root = Path.expand(root)
    expanded = Path.expand(path, root)
    expanded == root or String.starts_with?(expanded, String.trim_trailing(root, "/") <> "/")
  end

  @spec type_error!([atom() | String.t()], String.t(), term()) :: no_return()
  defp type_error!(path, expected, value) do
    fail!("#{join(path)} must be #{expected}, got #{inspect(value)}")
  end

  defp key_name([], key), do: inspect(key)
  defp key_name(path, key), do: join(path ++ [key])

  defp prefixed([], message), do: message
  defp prefixed(path, message), do: "#{join(path)} #{message}"

  defp join(path), do: Enum.map_join(path, ".", &to_string/1)

  @spec fail!(String.t()) :: no_return()
  defp fail!(message), do: Mix.raise("ash_quint.exs: " <> message)
end

defmodule AshQuint.Config.Model do
  @moduledoc """
  One model's settings from `ash_quint.exs`, with every default resolved.
  See `AshQuint.Config`.
  """

  @enforce_keys [:name, :model, :tests, :out, :on_missing_model, :seed]
  defstruct name: nil,
            model: nil,
            tests: nil,
            out: nil,
            on_missing_model: :fail,
            backend: nil,
            seed: nil,
            action_path: ["lastAction"],
            result_path: ["lastResult"],
            pending_result: "Pending",
            op_field: "op",
            init_action: "Init",
            random: nil,
            witnesses: nil,
            scenarios: nil,
            shrink: nil

  @type t :: %__MODULE__{
          name: atom(),
          model: String.t(),
          tests: String.t(),
          out: String.t(),
          on_missing_model: AshQuint.Config.on_missing_model(),
          backend: AshQuint.Config.backend() | nil,
          seed: integer(),
          action_path: [String.t()],
          result_path: [String.t()],
          pending_result: String.t(),
          op_field: String.t(),
          init_action: String.t(),
          random: keyword() | nil,
          witnesses: keyword() | nil,
          scenarios: keyword() | nil,
          shrink: keyword() | nil
        }

  @doc """
  The `AshQuint.Replay.run/3` options the model's settings give: `:model`
  (its name), `:action_path`, `:result_path`, `:pending_result`,
  `:op_field` and `:init_action`. `AshQuint.Case` and `AshQuint.Explore`
  add the test module's `adapter_opts` and `replay:` timeouts.
  """
  @spec replay_opts(t()) :: keyword()
  def replay_opts(%__MODULE__{} = model) do
    [
      model: model.name,
      action_path: model.action_path,
      result_path: model.result_path,
      pending_result: model.pending_result,
      op_field: model.op_field,
      init_action: model.init_action
    ]
  end
end
