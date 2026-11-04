defmodule AshQuint.Gen do
  @moduledoc """
  Generates a model's traces with Quint and builds its manifest: the logic
  behind `mix ash_quint.gen`.

  For each model, `generate/3` runs, from the project root:

    * **random:** `quint run <model> --main --seed [--init] [--step] [--max-steps]
      [--max-samples] [--n-traces] --out-itf=<tmp>/random_{seq}.itf.json`.
      Any non-zero exit is an error.
    * **witnesses:** for each name, `quint run <model> --main --seed
      [--init] [--step] [--max-steps] [--max-samples] --invariant=not(<name>)
      --out-itf=<tmp>/witness_<name>.itf.json`. The witness is reached when
      Quint exits non-zero, the file exists and its `#meta.status` is
      `"violation"`.
    * **scenarios:** `quint test <tests> --main [--match] --seed
      --out-itf=<tmp>/scenario_{test}_{seq}.itf.json`; each file is renamed
      to `scenario_<test>.itf.json`. Any non-zero exit is an error.

  Every file is normalized with `normalize/1`. Nothing is written by
  `generate/3`; `write!/2` writes one model's result.
  """

  alias AshQuint.Config
  alias AshQuint.Config.Model
  alias AshQuint.ITF
  alias AshQuint.Manifest
  alias AshQuint.Step

  @type command :: %{
          kind: :random | :witness | :scenario,
          name: String.t() | nil,
          cmd: [String.t()],
          args: [String.t()],
          out: String.t()
        }

  @type generated :: %{files: %{String.t() => binary()}, manifest: binary()}

  @type diff :: %{added: [String.t()], changed: [String.t()], removed: [String.t()]}

  @type runner :: (String.t(), [String.t()], keyword() -> {Collectable.t(), non_neg_integer()})

  @doc """
  The Quint commands for `model`, writing their traces into `tmp_dir`.
  `cmd` is the configured Quint command (see `AshQuint.Config.quint_cmd/1`)
  and `args` its arguments; `out` is the `--out-itf` path or pattern.
  """
  @spec commands(Config.t(), Model.t(), Path.t()) :: [command()]
  def commands(%Config{} = config, %Model{} = model, tmp_dir) do
    cmd = Config.quint_cmd(config)
    seed = "--seed=#{model.seed}"

    random =
      if opts = model.random do
        out = Path.join(tmp_dir, "random_{seq}.itf.json")

        args =
          ["run", model.model, "--main=#{opts[:main]}", seed] ++
            flags(opts, [:init, :step, :max_steps, :max_samples, :n_traces]) ++
            ["--out-itf=#{out}"]

        [%{kind: :random, name: nil, cmd: cmd, args: args, out: out}]
      else
        []
      end

    witnesses =
      if opts = model.witnesses do
        Enum.map(opts[:names], fn name ->
          out = Path.join(tmp_dir, "witness_#{name}.itf.json")

          args =
            ["run", model.model, "--main=#{opts[:main]}", seed] ++
              flags(opts, [:init, :step, :max_steps, :max_samples]) ++
              ["--invariant=not(#{name})", "--out-itf=#{out}"]

          %{kind: :witness, name: name, cmd: cmd, args: args, out: out}
        end)
      else
        []
      end

    scenarios =
      if opts = model.scenarios do
        out = Path.join(tmp_dir, "scenario_{test}_{seq}.itf.json")

        args =
          ["test", model.tests, "--main=#{opts[:main]}"] ++
            flags(opts, [:match]) ++ [seed, "--out-itf=#{out}"]

        [%{kind: :scenario, name: nil, cmd: cmd, args: args, out: out}]
      else
        []
      end

    random ++ witnesses ++ scenarios
  end

  defp flags(opts, keys) do
    for key <- keys, value = opts[key], value != nil do
      "--#{String.replace(Atom.to_string(key), "_", "-")}=#{value}"
    end
  end

  @doc """
  Generates the traces and manifest of each model in `models`, in memory.
  Returns the first error, and then nothing.

  Options:

    * `:runner` — `(cmd, args, opts -> {output, exit_status})`, called with
      `cd: config.root`; default `System.cmd/3` with stderr merged.
    * `:tmp_dir` — where the temporary traces go (default
      `System.tmp_dir!/0`): a new directory with a random name inside it,
      removed afterwards.
  """
  @spec generate(Config.t(), [Model.t()], keyword()) ::
          {:ok, %{atom() => generated()}} | {:error, String.t()}
  def generate(%Config{} = config, models, opts \\ []) do
    runner = Keyword.get(opts, :runner, &default_runner/3)
    base = Keyword.get_lazy(opts, :tmp_dir, &System.tmp_dir!/0)
    suffix = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    tmp = Path.join(base, "ash_quint_gen_" <> suffix)
    File.mkdir_p!(base)

    # File.mkdir/1 refuses an existing directory, so no leftover traces can
    # reach `out`, and only a directory created here is removed.
    case File.mkdir(tmp) do
      :ok ->
        try do
          generate_models(config, models, tmp, runner)
        after
          File.rm_rf!(tmp)
        end

      {:error, reason} ->
        {:error, "could not create temp directory #{tmp}: #{:file.format_error(reason)}"}
    end
  end

  defp generate_models(config, models, tmp, runner) do
    # Numbered, not named, so a model name can't lead outside `tmp`.
    models
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, fn {model, index}, {:ok, acc} ->
      model_tmp = Path.join(tmp, Integer.to_string(index))
      File.mkdir!(model_tmp)

      case generate_model(config, model, model_tmp, runner) do
        {:ok, generated} -> {:cont, {:ok, Map.put(acc, model.name, generated)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp default_runner(cmd, args, opts) do
    System.cmd(cmd, args, opts ++ [stderr_to_stdout: true])
  end

  defp generate_model(config, model, tmp, runner) do
    with :ok <- check_files(config, model),
         :ok <- run_all(config, model, tmp, runner),
         {:ok, files} <- collect(model, tmp) do
      build(config, model, files)
    end
  end

  defp check_files(config, model) do
    files =
      [{"model", model.model}] ++ if(model.scenarios, do: [{"tests", model.tests}], else: [])

    Enum.find_value(files, :ok, fn {label, path} ->
      unless File.regular?(Path.join(config.root, path)) do
        {:error, "model #{inspect(model.name)}: #{label} file #{path} is missing"}
      end
    end)
  end

  defp run_all(config, model, tmp, runner) do
    config
    |> commands(model, tmp)
    |> Enum.reduce_while(:ok, fn command, :ok ->
      case run(command, config, model, runner) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp run(%{cmd: [exe | pre]} = command, config, model, runner) do
    {output, status} = runner.(exe, pre ++ command.args, cd: config.root)
    check_run(command, model, IO.iodata_to_binary(output), status)
  rescue
    error in ErlangError ->
      if error.original == :enoent do
        {:error, "could not run Quint (#{Enum.join(command.cmd, " ")}): executable not found"}
      else
        reraise error, __STACKTRACE__
      end
  end

  defp check_run(%{kind: :random}, _model, _output, 0), do: :ok

  defp check_run(%{kind: :random}, model, output, _status),
    do: {:error, "quint run for #{inspect(model.name)} random failed:\n#{output}"}

  defp check_run(%{kind: :scenario}, _model, _output, 0), do: :ok

  defp check_run(%{kind: :scenario}, model, output, _status),
    do: {:error, "quint test for #{inspect(model.name)} failed:\n#{output}"}

  defp check_run(%{kind: :witness} = command, model, output, status) do
    if status != 0 and violation?(command.out) do
      :ok
    else
      {:error, "witness #{command.name} of #{inspect(model.name)} was not reached:\n#{output}"}
    end
  end

  defp violation?(path) do
    with {:ok, binary} <- File.read(path),
         {:ok, %{"#meta" => %{"status" => "violation"}}} <- Jason.decode(binary) do
      true
    else
      _other -> false
    end
  end

  defp collect(model, tmp) do
    tmp
    |> File.ls!()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn file, {:ok, acc} ->
      name = final_name(file)

      if Map.has_key?(acc, name) do
        "scenario_" <> rest = name
        test = String.trim_trailing(rest, ".itf.json")

        {:halt,
         {:error, "scenario #{test} of #{inspect(model.name)} produced more than one trace"}}
      else
        {:cont, {:ok, Map.put(acc, name, normalize(File.read!(Path.join(tmp, file))))}}
      end
    end)
  end

  # Quint's {seq} in `quint test` is the test's index in the run, so each
  # test writes one file: scenario_<test>_<seq>.itf.json.
  defp final_name(file) do
    case Regex.run(~r/\Ascenario_(.+)_\d+\.itf\.json\z/, file) do
      [_, test] -> "scenario_#{test}.itf.json"
      nil -> file
    end
  end

  defp build(config, model, files) do
    entries =
      Enum.map(files, fn {file, binary} ->
        {source, name} = source_and_name(file)
        trace = ITF.decode!(Jason.decode!(binary), file)
        entry(file, source, name, trace, model)
      end)

    paths = [model.model] ++ if(model.scenarios, do: [model.tests], else: [])

    manifest = %Manifest{
      quint: config.quint,
      seed: model.seed,
      models: Map.new(paths, &{&1, Manifest.hash_file(Path.join(config.root, &1))}),
      traces: entries
    }

    {:ok, %{files: files, manifest: Manifest.encode(manifest)}}
  rescue
    error in [ArgumentError, ITF.Error] ->
      {:error, "model #{inspect(model.name)}: " <> Exception.message(error)}
  end

  defp source_and_name("random_" <> rest), do: {:random, trim_ext(rest)}
  defp source_and_name("witness_" <> rest), do: {:witness, trim_ext(rest)}
  defp source_and_name("scenario_" <> rest), do: {:scenario, trim_ext(rest)}

  defp trim_ext(file), do: String.replace_suffix(file, ".itf.json", "")

  @doc """
  The manifest entry for a generated trace: `steps` is the number of states
  after the initial one, `actions` counts their action tags, and `outcomes`
  counts, per action, their result labels (`AshQuint.Step.result_label/1`;
  steps without a result aren't counted there). States are read with the
  model's `action_path` and `result_path`. Raises `ArgumentError` when a
  state's action or result can't be read.
  """
  @spec entry(String.t(), AshQuint.Trace.source(), String.t(), AshQuint.Trace.t(), Model.t()) ::
          Manifest.entry()
  def entry(file, source, name, trace, %Model{} = model) do
    opts = [action_path: model.action_path, result_path: model.result_path]

    steps =
      trace.states
      |> Enum.with_index()
      |> Enum.drop(1)
      |> Enum.map(fn {state, index} ->
        case Step.from_state(state, index, opts) do
          {:ok, step} -> {step.action_taken, Step.result_label(step.result)}
          {:error, reason} -> raise ArgumentError, "#{file}, state #{index}: #{reason}"
        end
      end)

    actions = steps |> Enum.map(&elem(&1, 0)) |> Enum.frequencies()

    outcomes =
      steps
      |> Enum.reject(fn {_action, label} -> is_nil(label) end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {action, labels} -> {action, Enum.frequencies(labels)} end)

    %{
      file: file,
      source: source,
      name: name,
      steps: length(trace.states) - 1,
      actions: actions,
      outcomes: outcomes
    }
  end

  @doc """
  Normalizes a trace as Quint wrote it: removes `description` and
  `timestamp` from the top-level `#meta` and keeps everything else, key
  order included. The result is compact JSON without a trailing newline.
  """
  @spec normalize(binary()) :: binary()
  def normalize(binary) do
    %Jason.OrderedObject{values: values} = Jason.decode!(binary, objects: :ordered_objects)

    values =
      Enum.map(values, fn
        {"#meta", %Jason.OrderedObject{values: meta}} ->
          {"#meta",
           %Jason.OrderedObject{
             values: Enum.reject(meta, fn {key, _} -> key in ["description", "timestamp"] end)
           }}

        other ->
          other
      end)

    Jason.encode!(%Jason.OrderedObject{values: values})
  end

  @doc """
  Compares one model's generated files with `out_dir`, over `*.itf.json`
  and `manifest.json` only. Each list is sorted.
  """
  @spec diff(Path.t(), generated()) :: diff()
  def diff(out_dir, generated) do
    new = all_files(generated)
    old = existing(out_dir)

    %{
      added: new |> Map.keys() |> Enum.reject(&(&1 in old)) |> Enum.sort(),
      changed:
        old
        |> Enum.filter(&(Map.has_key?(new, &1) and File.read!(Path.join(out_dir, &1)) != new[&1]))
        |> Enum.sort(),
      removed: old |> Enum.reject(&Map.has_key?(new, &1)) |> Enum.sort()
    }
  end

  @doc """
  Writes one model's generated files into `out_dir`, creating it, and
  removes the `*.itf.json` files it no longer has. Other files are left
  alone.
  """
  @spec write!(Path.t(), generated()) :: :ok
  def write!(out_dir, generated) do
    new = all_files(generated)
    File.mkdir_p!(out_dir)

    out_dir
    |> existing()
    |> Enum.reject(&Map.has_key?(new, &1))
    |> Enum.each(&File.rm!(Path.join(out_dir, &1)))

    Enum.each(new, fn {file, binary} -> File.write!(Path.join(out_dir, file), binary) end)
  end

  defp all_files(%{files: files, manifest: manifest}),
    do: Map.put(files, "manifest.json", manifest)

  defp existing(out_dir) do
    case File.ls(out_dir) do
      {:ok, files} ->
        Enum.filter(files, &(&1 == "manifest.json" or String.ends_with?(&1, ".itf.json")))

      {:error, _reason} ->
        []
    end
  end
end
