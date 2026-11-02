defmodule AshQuint.Manifest do
  @moduledoc """
  Reads and writes `<out>/manifest.json`, the record of the traces
  `mix ash_quint.gen` generated for a model:

      {
        "ash_quint": 1,
        "models": { "test/quint/counter/model.qnt": "sha256:…" },
        "quint": "0.33.1",
        "seed": 20261102,
        "traces": [
          { "actions": { "Inc": 2, "Reset": 1 }, "file": "random_0.itf.json",
            "name": "0", "source": "random", "steps": 3 }
        ]
      }

  `models` maps each model file, as configured, to its hash. The encoding is
  deterministic: keys sorted at every level, traces sorted by file name,
  no timestamps.
  """

  @version 1

  defstruct version: @version, quint: nil, seed: nil, models: %{}, traces: []

  @type entry :: %{
          file: String.t(),
          source: AshQuint.Trace.source(),
          name: String.t(),
          steps: non_neg_integer(),
          actions: %{String.t() => pos_integer()}
        }

  @type t :: %__MODULE__{
          version: 1,
          quint: String.t(),
          seed: integer(),
          models: %{String.t() => String.t()},
          traces: [entry()]
        }

  @sources %{"random" => :random, "witness" => :witness, "scenario" => :scenario}

  @doc """
  The hash of the file at `path`: `"sha256:"` followed by lowercase hex.
  """
  @spec hash_file(Path.t()) :: String.t()
  def hash_file(path) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, File.read!(path)), case: :lower)
  end

  @doc """
  Encodes `manifest` as pretty-printed JSON with sorted keys, traces sorted
  by file and a trailing newline.
  """
  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = manifest) do
    traces =
      manifest.traces
      |> Enum.sort_by(& &1.file)
      |> Enum.map(fn entry ->
        ordered(%{
          "actions" => ordered(entry.actions),
          "file" => entry.file,
          "name" => entry.name,
          "source" => Atom.to_string(entry.source),
          "steps" => entry.steps
        })
      end)

    json =
      ordered(%{
        "ash_quint" => manifest.version,
        "models" => ordered(manifest.models),
        "quint" => manifest.quint,
        "seed" => manifest.seed,
        "traces" => traces
      })

    Jason.encode!(json, pretty: true) <> "\n"
  end

  @doc """
  Reads the manifest at `path`. A missing file raises `File.Error`; an
  invalid one raises `ArgumentError` (see `decode!/2`).
  """
  @spec read!(Path.t()) :: t()
  def read!(path), do: path |> File.read!() |> decode!(path)

  @doc """
  Decodes manifest JSON. `path` is used in error messages. Raises
  `ArgumentError` for invalid JSON, a version other than 1, an unknown
  trace source or a malformed field.
  """
  @spec decode!(binary(), String.t()) :: t()
  def decode!(binary, path) do
    case Jason.decode(binary) do
      {:ok, %{"ash_quint" => @version} = json} ->
        from_json(json, path)

      {:ok, %{"ash_quint" => version}} ->
        fail!(path, "unsupported manifest version #{inspect(version)}")

      {:ok, _json} ->
        fail!(path, "not an ash_quint manifest")

      {:error, error} ->
        fail!(path, "invalid JSON: " <> Exception.message(error))
    end
  end

  defp from_json(json, path) do
    quint = field!(json, "quint", &is_binary/1, "a string", path)
    seed = field!(json, "seed", &is_integer/1, "an integer", path)
    models = field!(json, "models", &string_map?/1, "a map of strings", path)
    traces = field!(json, "traces", &is_list/1, "a list", path)

    %__MODULE__{
      quint: quint,
      seed: seed,
      models: models,
      traces: traces |> Enum.with_index() |> Enum.map(&entry!(&1, path))
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
          }, _index},
         path
       )
       when is_binary(file) and is_binary(source) and is_binary(name) and is_integer(steps) and
              steps >= 0 and is_map(actions) do
    if Enum.all?(actions, fn {k, v} -> is_binary(k) and is_integer(v) and v > 0 end) do
      %{
        file: file,
        source: source!(source, file, path),
        name: name,
        steps: steps,
        actions: actions
      }
    else
      fail!(path, "invalid manifest: actions of #{file} must map names to positive integers")
    end
  end

  defp entry!({_entry, index}, path) do
    fail!(path, "invalid manifest: traces[#{index}] is malformed")
  end

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
