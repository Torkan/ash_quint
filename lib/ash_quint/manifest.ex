defmodule AshQuint.Manifest do
  @moduledoc """
  Reads and writes `<out>/manifest.json`, the record of the traces
  `mix ash_quint.gen` generated for a model:

      {
        "ash_quint": 3,
        "interface": {
          "actions": [
            { "name": "Init", "picks": "unit" },
            { "fields": [{ "name": "ctr", "type": "str" }, { "name": "by", "type": "int" }],
              "name": "Inc", "picks": "record" },
            { "name": "Reset", "picks": "value", "type": "str" }
          ],
          "results": ["Accepted", "Rejected"],
          "vars": [{ "name": "counts", "type": "str -> int" }]
        },
        "models": { "test/quint/counter/model.qnt": "sha256:…" },
        "quint": "0.33.1",
        "seed": 20261102,
        "traces": [
          { "actions": { "Inc": 2, "Reset": 1 }, "file": "random_0.itf.json",
            "name": "0",
            "outcomes": { "Inc": { "accepted": 1, "rejected:over_limit": 1 },
                          "Reset": { "accepted": 1 } },
            "source": "random", "steps": 3 },
          { "actions": { "IncDone": 2, "IncStart": 2 }, "concurrent": true,
            "file": "scenario_raceTest.itf.json", "max_in_flight": 2,
            "name": "raceTest",
            "outcomes": { "IncDone": { "accepted": 1, "rejected:over_limit": 1 },
                          "IncStart": { "pending": 2 } },
            "source": "scenario", "steps": 4 }
        ]
      }

  `interface` is the model's interface, read from Quint by
  `mix ash_quint.gen` (see `AshQuint.Interface`): its actions with their
  pick shapes, its result variants (`null` without a result variable) and
  its other variables, with their types as Quint text. Its lists keep the
  model's declaration order. `models` maps each model file, as configured,
  to its hash. `actions`
  counts each action tag over the trace's steps; `outcomes` counts, per
  action, the steps' result labels (see `AshQuint.Step.result_label/1`).
  A step without a result (the model has no `lastResult`) is counted in
  `actions` only, so a model without results has empty `outcomes`.

  A trace is `concurrent` when a call is in flight in it: some step's
  result is `Pending` (see `AshQuint.Step`). `max_in_flight` is the most
  operations in flight at once. Both keys are written only for concurrent
  traces and are optional on read, in every format version: absent means
  `concurrent: false` and `max_in_flight: 0`.

  `source` is `random`, `witness`, `scenario` or `regression`. A
  regression entry (a trace committed by `mix ash_quint.promote`, named
  `<seed>_<index>`) also has its own `seed`, the seed it was found with,
  which its replay uses instead of the manifest's. `seed` is written only
  for entries that have one and is optional on read; when present it must
  be an integer.

  The encoding is deterministic: keys sorted at every level, traces sorted by
  file name, no timestamps.

  ## Format versions

  `"ash_quint"` is the format version. `encode/1` writes version 3.
  `decode!/2` also reads version 2, written before the `interface` was
  recorded (it decodes with `interface: nil`), and version 1, written
  before `outcomes` was recorded: its entries get `outcomes: nil`. A
  decoded manifest keeps its `version`, so replays keep working and
  `mix ash_quint.coverage` can ask for a regeneration.
  """

  alias AshQuint.Interface

  @version 3
  @versions [1, 2, 3]

  defstruct version: @version, quint: nil, seed: nil, models: %{}, traces: [], interface: nil

  @type outcomes :: %{String.t() => %{String.t() => pos_integer()}}

  @type entry :: %{
          required(:file) => String.t(),
          required(:source) => AshQuint.Trace.source(),
          required(:name) => String.t(),
          required(:steps) => non_neg_integer(),
          required(:actions) => %{String.t() => pos_integer()},
          required(:outcomes) => outcomes() | nil,
          required(:concurrent) => boolean(),
          required(:max_in_flight) => non_neg_integer(),
          optional(:seed) => integer()
        }

  @type t :: %__MODULE__{
          version: 1 | 2 | 3,
          interface: AshQuint.Interface.t() | nil,
          quint: String.t(),
          seed: integer(),
          models: %{String.t() => String.t()},
          traces: [entry()]
        }

  @sources %{
    "random" => :random,
    "witness" => :witness,
    "scenario" => :scenario,
    "regression" => :regression
  }

  @doc """
  The hash of the file at `path`: `"sha256:"` followed by lowercase hex.
  """
  @spec hash_file(Path.t()) :: String.t()
  def hash_file(path) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, File.read!(path)), case: :lower)
  end

  @doc """
  Encodes `manifest` as pretty-printed JSON with sorted keys, traces sorted
  by file and a trailing newline. Always writes the current format
  version, so the manifest needs its `interface` and every entry its
  `outcomes`: raises `ArgumentError` without them.
  """
  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{interface: nil}),
    do: raise(ArgumentError, "manifest has no interface")

  def encode(%__MODULE__{} = manifest) do
    traces =
      manifest.traces
      |> Enum.sort_by(& &1.file)
      |> Enum.map(fn entry ->
        %{
          "actions" => ordered(entry.actions),
          "file" => entry.file,
          "name" => entry.name,
          "outcomes" => encode_outcomes(entry),
          "source" => Atom.to_string(entry.source),
          "steps" => entry.steps
        }
        |> Map.merge(concurrency(entry))
        |> Map.merge(entry_seed(entry))
        |> ordered()
      end)

    json =
      ordered(%{
        "ash_quint" => @version,
        "interface" => Interface.to_json(manifest.interface),
        "models" => ordered(manifest.models),
        "quint" => manifest.quint,
        "seed" => manifest.seed,
        "traces" => traces
      })

    Jason.encode!(json, pretty: true) <> "\n"
  end

  defp encode_outcomes(%{outcomes: outcomes}) when is_map(outcomes) do
    outcomes |> Map.new(fn {action, labels} -> {action, ordered(labels)} end) |> ordered()
  end

  defp encode_outcomes(entry) do
    raise ArgumentError, "manifest entry #{entry.file} has no outcomes"
  end

  # Written only when true, so sequential models' manifests don't change.
  defp concurrency(%{concurrent: true, max_in_flight: max}),
    do: %{"concurrent" => true, "max_in_flight" => max}

  defp concurrency(_entry), do: %{}

  defp entry_seed(%{seed: seed}), do: %{"seed" => seed}
  defp entry_seed(_entry), do: %{}

  @doc """
  Reads the manifest at `path`. A missing file raises `File.Error`; an
  invalid one raises `ArgumentError` (see `decode!/2`).
  """
  @spec read!(Path.t()) :: t()
  def read!(path), do: path |> File.read!() |> decode!(path)

  @doc """
  Decodes manifest JSON. `path` is used in error messages. Raises
  `ArgumentError` for invalid JSON, a version other than 1, 2 or 3, an
  unknown trace source or a malformed field (version 3 needs an
  `interface`).
  """
  @spec decode!(binary(), String.t()) :: t()
  def decode!(binary, path) do
    case Jason.decode(binary) do
      {:ok, %{"ash_quint" => version} = json} when version in @versions ->
        from_json(json, version, path)

      {:ok, %{"ash_quint" => version}} ->
        fail!(path, "unsupported manifest version #{inspect(version)}")

      {:ok, _json} ->
        fail!(path, "not an ash_quint manifest")

      {:error, error} ->
        fail!(path, "invalid JSON: " <> Exception.message(error))
    end
  end

  defp from_json(json, version, path) do
    quint = field!(json, "quint", &is_binary/1, "a string", path)
    seed = field!(json, "seed", &is_integer/1, "an integer", path)
    models = field!(json, "models", &string_map?/1, "a map of strings", path)
    traces = field!(json, "traces", &is_list/1, "a list", path)

    %__MODULE__{
      version: version,
      interface: if(version >= 3, do: Interface.from_json!(Map.get(json, "interface"), path)),
      quint: quint,
      seed: seed,
      models: models,
      traces: traces |> Enum.with_index() |> Enum.map(&entry!(&1, version, path))
    }
  end

  defp field!(json, key, valid?, expected, path) do
    value = Map.get(json, key)

    if valid?.(value),
      do: value,
      else: fail!(path, "invalid manifest: #{key} must be #{expected}")
  end

  defp entry!(
         {%{
            "file" => file,
            "source" => source,
            "name" => name,
            "steps" => steps,
            "actions" => actions
          } = json, index},
         version,
         path
       )
       when is_binary(file) and is_binary(source) and is_binary(name) and is_integer(steps) and
              steps >= 0 and is_map(actions) do
    unless counts?(actions) do
      fail!(path, "invalid manifest: actions of #{file} must map names to positive integers")
    end

    %{
      file: file,
      source: source!(source, file, path),
      name: name,
      steps: steps,
      actions: actions,
      outcomes: outcomes!(json, version, file, index, path)
    }
    |> Map.merge(concurrency!(json, file, path))
    |> Map.merge(seed!(json, file, path))
  end

  defp entry!({_entry, index}, _version, path) do
    fail!(path, "invalid manifest: traces[#{index}] is malformed")
  end

  defp outcomes!(_json, 1, _file, _index, _path), do: nil

  defp outcomes!(%{"outcomes" => outcomes}, _version, file, _index, path) do
    if is_map(outcomes) and
         Enum.all?(outcomes, fn {k, v} -> is_binary(k) and is_map(v) and counts?(v) end) do
      outcomes
    else
      fail!(
        path,
        "invalid manifest: outcomes of #{file} must map actions to maps of " <>
          "labels to positive integers"
      )
    end
  end

  defp outcomes!(_json, _version, _file, index, path) do
    fail!(path, "invalid manifest: traces[#{index}] is malformed")
  end

  defp concurrency!(json, file, path) do
    case {Map.get(json, "concurrent", false), Map.get(json, "max_in_flight", 0)} do
      {false, 0} ->
        %{concurrent: false, max_in_flight: 0}

      {true, max} when is_integer(max) and max > 0 ->
        %{concurrent: true, max_in_flight: max}

      _other ->
        fail!(
          path,
          "invalid manifest: concurrent and max_in_flight of #{file} must be absent, " <>
            "or true and a positive integer"
        )
    end
  end

  defp seed!(%{"seed" => seed}, _file, _path) when is_integer(seed), do: %{seed: seed}

  defp seed!(%{"seed" => _seed}, file, path),
    do: fail!(path, "invalid manifest: seed of #{file} must be an integer")

  defp seed!(_json, _file, _path), do: %{}

  defp counts?(map),
    do: Enum.all?(map, fn {k, v} -> is_binary(k) and is_integer(v) and v > 0 end)

  defp source!(source, file, path) do
    case Map.fetch(@sources, source) do
      {:ok, atom} -> atom
      :error -> fail!(path, "unknown source #{inspect(source)} for trace #{file}")
    end
  end

  defp string_map?(map) when is_map(map),
    do: Enum.all?(map, fn {k, v} -> is_binary(k) and is_binary(v) end)

  defp string_map?(_value), do: false

  defp ordered(map) do
    map |> Enum.sort_by(fn {key, _value} -> key end) |> Jason.OrderedObject.new()
  end

  defp fail!(path, reason), do: raise(ArgumentError, "#{path}: #{reason}")
end
