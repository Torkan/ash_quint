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

  Every file is normalized with `normalize/1`. Then, to record the model's
  interface (see `AshQuint.Interface`) in the manifest, it runs:

    * **interface:** `quint compile --target=json --main=<main> <file>
      --out=<tmp>/<index>.interface.json`, with `<main>` and `<file>` from
      `random:` (the model file), else `witnesses:` (the model file), else
      `scenarios:` (the tests file). Any non-zero exit is an error, as is
      an IR the interface can't be read from (see `interface_command/3`).

  ## Regression traces

  A `regression_<name>.itf.json` file in the model's `out` directory is a
  trace `mix ash_quint.promote` committed. It isn't generated, so
  `generate/3` keeps it: it adds the file to `files` byte for byte, with
  its entry built by `regression_entry!/3`, so `write!/2` leaves it as it
  is and `diff/2` never reports it. A regression file whose provenance
  (`provenance/1`) records another model hash than the model file's
  current one is still kept, with a note in `notes`: gen can't tell
  whether the trace is still a behaviour of the new model. A regression
  file without provenance is an error. Deleting a regression file drops
  its entry at the next generation.

  Nothing is written by `generate/3`; `write!/2` writes one model's result.
  """

  alias AshQuint.Config
  alias AshQuint.Config.Model
  alias AshQuint.Interface
  alias AshQuint.ITF
  alias AshQuint.Manifest
  alias AshQuint.Step

  @type command :: %{
          kind: :random | :witness | :scenario | :interface,
          name: String.t() | nil,
          cmd: [String.t()],
          args: [String.t()],
          out: String.t()
        }

  @type generated :: %{
          files: %{String.t() => binary()},
          manifest: binary(),
          notes: [String.t()]
        }

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
      if model.random do
        out = Path.join(tmp_dir, "random_{seq}.itf.json")
        args = random_args(model, model.seed, out: out)
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

  @doc """
  The `quint compile` command that writes `model`'s JSON IR to `path`,
  from which `generate/3` reads its interface. The main module and file
  come from `random:` (the model file), else `witnesses:` (the model
  file), else `scenarios:` (the tests file).
  """
  @spec interface_command(Config.t(), Model.t(), Path.t()) :: command()
  def interface_command(%Config{} = config, %Model{} = model, path) do
    {main, file} =
      cond do
        model.random -> {model.random[:main], model.model}
        model.witnesses -> {model.witnesses[:main], model.model}
        true -> {model.scenarios[:main], model.tests}
      end

    %{
      kind: :interface,
      name: nil,
      cmd: Config.quint_cmd(config),
      args: ["compile", "--target=json", "--main=#{main}", file, "--out=#{path}"],
      out: path
    }
  end

  @doc """
  The `quint run` arguments for `model`'s `random:` source with `seed`:
  what `commands/3` runs (with the model's seed), and what
  `AshQuint.Explore` runs per batch. `overrides` replace the configured
  `:n_traces`, `:max_samples` and `:max_steps`; `:out`, the `--out-itf`
  path or pattern, is required.
  """
  @spec random_args(Model.t(), integer(), keyword()) :: [String.t()]
  def random_args(%Model{random: random} = model, seed, overrides) when is_list(random) do
    {out, overrides} = Keyword.pop!(overrides, :out)
    opts = Keyword.merge(random, Keyword.take(overrides, [:n_traces, :max_samples, :max_steps]))

    ["run", model.model, "--main=#{opts[:main]}", "--seed=#{seed}"] ++
      flags(opts, [:init, :step, :max_steps, :max_samples, :n_traces]) ++
      ["--out-itf=#{out}"]
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
      # Beside the model's dir, not in it, so collect/2 never sees it.
      ir_path = Path.join(tmp, "#{index}.interface.json")

      case generate_model(config, model, {model_tmp, ir_path}, runner) do
        {:ok, generated} -> {:cont, {:ok, Map.put(acc, model.name, generated)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp default_runner(cmd, args, opts) do
    System.cmd(cmd, args, opts ++ [stderr_to_stdout: true])
  end

  defp generate_model(config, model, {tmp, ir_path}, runner) do
    with :ok <- check_files(config, model),
         :ok <- run_all(config, model, tmp, runner),
         {:ok, files} <- collect(model, tmp),
         {:ok, interface} <- interface(config, model, ir_path, runner) do
      build(config, model, files, interface)
    end
  end

  defp interface(config, model, path, runner) do
    command = interface_command(config, model, path)

    case run_quint(config, command.args, runner) do
      {:ok, _output, 0} ->
        opts = [
          action_path: model.action_path,
          result_path: model.result_path,
          quint: config.quint
        ]

        with {:ok, ir} <- read_ir(path, config.quint),
             {:ok, interface} <- Interface.from_ir(ir, opts) do
          {:ok, interface}
        else
          {:error, reason} -> {:error, "model #{inspect(model.name)}: #{reason}"}
        end

      {:ok, output, _status} ->
        {:error, "quint compile for #{inspect(model.name)} failed:\n#{output}"}

      {:error, _reason} = error ->
        error
    end
  end

  defp read_ir(path, quint) do
    unreadable = "could not read the model interface from Quint #{quint}'s JSON IR: "

    case File.read(path) do
      {:ok, binary} ->
        case Jason.decode(binary) do
          {:ok, ir} -> {:ok, ir}
          {:error, _error} -> {:error, unreadable <> "invalid JSON in the --out file"}
        end

      {:error, reason} ->
        {:error, unreadable <> "no --out file (#{:file.format_error(reason)})"}
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

  defp run(command, config, model, runner) do
    case run_quint(config, command.args, runner) do
      {:ok, output, status} -> check_run(command, model, output, status)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Runs Quint (`AshQuint.Config.quint_cmd/1`) with `args` in the project
  root through `runner` (see `generate/3`), returning its output and exit
  status. A missing executable is an error; any other runner error is
  raised.
  """
  @spec run_quint(Config.t(), [String.t()], runner()) ::
          {:ok, String.t(), non_neg_integer()} | {:error, String.t()}
  def run_quint(%Config{} = config, args, runner) do
    [exe | pre] = Config.quint_cmd(config)
    {output, status} = runner.(exe, pre ++ args, cd: config.root)
    {:ok, IO.iodata_to_binary(output), status}
  rescue
    error in ErlangError ->
      if error.original == :enoent do
        {:error,
         "could not run Quint (#{Enum.join(Config.quint_cmd(config), " ")}): executable not found"}
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

  defp build(config, model, files, interface) do
    entries =
      Enum.map(files, fn {file, binary} ->
        {source, name} = source_and_name(file)
        trace = ITF.decode!(Jason.decode!(binary), file)
        entry(file, source, name, trace, model)
      end)

    model_hash = Manifest.hash_file(Path.join(config.root, model.model))
    regressions = regressions(config, model)

    regression_entries =
      Enum.map(regressions, fn {file, binary} -> regression_entry!(file, binary, model) end)

    notes =
      for {file, binary} <- regressions,
          {:ok, provenance} = provenance(binary),
          provenance["model_hash"] != model_hash do
        "#{model.name}: #{file} was found against an earlier model; " <>
          "delete it if it no longer applies"
      end

    paths = [model.model] ++ if(model.scenarios, do: [model.tests], else: [])

    manifest = %Manifest{
      interface: interface,
      quint: config.quint,
      seed: model.seed,
      models: Map.new(paths, &{&1, Manifest.hash_file(Path.join(config.root, &1))}),
      traces: entries ++ regression_entries
    }

    files = Map.merge(files, Map.new(regressions))
    {:ok, %{files: files, manifest: Manifest.encode(manifest), notes: notes}}
  rescue
    error in [ArgumentError, ITF.Error] ->
      {:error, "model #{inspect(model.name)}: " <> Exception.message(error)}
  end

  defp regressions(config, model) do
    [config.root, model.out, "regression_*.itf.json"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&{Path.basename(&1), File.read!(&1)})
  end

  defp source_and_name("random_" <> rest), do: {:random, trim_ext(rest)}
  defp source_and_name("witness_" <> rest), do: {:witness, trim_ext(rest)}
  defp source_and_name("scenario_" <> rest), do: {:scenario, trim_ext(rest)}

  defp trim_ext(file), do: String.replace_suffix(file, ".itf.json", "")

  @doc """
  The manifest entry for the regression trace `binary`, the contents of
  `file` (`regression_<name>.itf.json`): `entry/5` with source
  `:regression` and the name from the file name, plus the `seed` from its
  provenance (see `provenance/1`). Raises `ArgumentError` when the trace
  has no provenance or its seed isn't an integer.
  """
  @spec regression_entry!(String.t(), binary(), Model.t()) :: Manifest.entry()
  def regression_entry!(file, binary, %Model{} = model) do
    seed =
      case provenance(binary) do
        {:ok, %{"seed" => seed}} when is_integer(seed) ->
          seed

        {:ok, _provenance} ->
          raise ArgumentError, "#{file}: #meta.ash_quint.seed must be an integer"

        :error ->
          raise ArgumentError,
                "#{file} has no #meta.ash_quint; " <>
                  "only mix ash_quint.promote writes regression traces"
      end

    "regression_" <> name = trim_ext(file)
    trace = ITF.decode!(Jason.decode!(binary), file)

    file
    |> entry(:regression, name, trace, model)
    |> Map.put(:seed, seed)
  end

  @doc """
  A trace's provenance: the top-level `#meta.ash_quint` object, with
  string keys, which records where an explored trace came from (model,
  model hash, seed, index, Quint version and arguments). `:error` when
  the trace has none, or it isn't an object.
  """
  @spec provenance(binary()) :: {:ok, map()} | :error
  def provenance(binary) do
    case Jason.decode(binary) do
      {:ok, %{"#meta" => %{"ash_quint" => provenance}}} when is_map(provenance) ->
        {:ok, provenance}

      _other ->
        :error
    end
  end

  @doc """
  Sets a trace's provenance (see `provenance/1`): `#meta.ash_quint`
  becomes `provenance`, with its keys sorted, replacing an earlier one in
  place or else appended to the top-level `#meta`. Everything else is
  kept, key order included. Like `normalize/1`, the result is compact
  JSON without a trailing newline.
  """
  @spec put_provenance(binary(), map()) :: binary()
  def put_provenance(binary, provenance) do
    %Jason.OrderedObject{values: values} = Jason.decode!(binary, objects: :ordered_objects)
    entry = {"ash_quint", sorted(provenance)}

    values =
      Enum.map(values, fn
        {"#meta", %Jason.OrderedObject{values: meta}} ->
          meta =
            if List.keymember?(meta, "ash_quint", 0),
              do: List.keyreplace(meta, "ash_quint", 0, entry),
              else: meta ++ [entry]

          {"#meta", %Jason.OrderedObject{values: meta}}

        other ->
          other
      end)

    Jason.encode!(%Jason.OrderedObject{values: values})
  end

  defp sorted(map) when is_map(map) do
    map |> Enum.sort_by(&elem(&1, 0)) |> Jason.OrderedObject.new()
  end

  @doc """
  The manifest entry for a generated trace: `steps` is the number of states
  after the initial one, `actions` counts their action tags, and `outcomes`
  counts, per action, their result labels (`AshQuint.Step.result_label/1`;
  steps without a result aren't counted there). An op is in flight from its
  first `Pending` step until a step of the same op that isn't `Pending`;
  `max_in_flight` is the most ops in flight at once, and `concurrent` is
  whether there ever was one. States are read with the model's
  `action_path`, `result_path`, `pending_result` and `op_field`. Raises
  `ArgumentError` when a state's action or result can't be read.
  """
  @spec entry(String.t(), AshQuint.Trace.source(), String.t(), AshQuint.Trace.t(), Model.t()) ::
          Manifest.entry()
  def entry(file, source, name, trace, %Model{} = model) do
    opts = [
      action_path: model.action_path,
      result_path: model.result_path,
      pending_result: model.pending_result,
      op_field: model.op_field
    ]

    steps =
      trace.states
      |> Enum.with_index()
      |> Enum.drop(1)
      |> Enum.map(fn {state, index} ->
        case Step.from_state(state, index, opts) do
          {:ok, step} -> step
          {:error, reason} -> raise ArgumentError, "#{file}, state #{index}: #{reason}"
        end
      end)

    outcomes =
      steps
      |> Enum.reject(&is_nil(&1.result))
      |> Enum.group_by(& &1.action_taken, &Step.result_label(&1.result))
      |> Map.new(fn {action, labels} -> {action, Enum.frequencies(labels)} end)

    max_in_flight = max_in_flight(steps)

    %{
      file: file,
      source: source,
      name: name,
      steps: length(trace.states) - 1,
      actions: steps |> Enum.map(& &1.action_taken) |> Enum.frequencies(),
      outcomes: outcomes,
      concurrent: max_in_flight > 0,
      max_in_flight: max_in_flight
    }
  end

  defp max_in_flight(steps) do
    {_in_flight, max} =
      Enum.reduce(steps, {MapSet.new(), 0}, fn
        %Step{result: :pending, op: op}, {in_flight, max} ->
          in_flight = MapSet.put(in_flight, op)
          {in_flight, max(max, MapSet.size(in_flight))}

        %Step{op: op}, {in_flight, max} ->
          {MapSet.delete(in_flight, op), max}
      end)

    max
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
