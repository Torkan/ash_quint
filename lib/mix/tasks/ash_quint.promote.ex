defmodule Mix.Tasks.AshQuint.Promote do
  @shortdoc "Commits explore candidates as regression traces"

  @moduledoc """
  Commits traces that explore found as regression traces of their model.

      mix ash_quint.promote <candidate> ...

  A candidate is a trace with its provenance in `#meta.ash_quint` (see
  `AshQuint.Gen.provenance/1`): the model, the model file's hash, the seed
  and the trace's index in its batch. Each one is copied, byte for byte,
  to `<out>/regression_<seed>_<index>.itf.json` in the model's `out`
  directory, and its entry (source `regression`, with its seed) is added
  to the model's `manifest.json`. Quint isn't run and nothing is
  regenerated: the file is the regression. `AshQuint.Case` then generates
  a `"regression <seed>_<index>"` test for it, replayed with its seed, and
  `mix ash_quint.gen` keeps it.

  Reads `ash_quint.exs` in the current directory. Every candidate is
  checked before anything is written, so one bad candidate writes nothing.
  It is an error when a candidate:

    * can't be read, or has no provenance;
    * names a model that isn't configured;
    * has no valid manifest for its model, or one older than format 3
      (written before the model interface was recorded; regenerate it);
    * was found against a version of the model file, unless it equals
      both the manifest's and the current one (regenerate and explore
      again);
    * would overwrite a regression trace already there, or one the
      manifest still lists after its file was deleted (regenerate first).

  Like `mix ash_quint.gen`, run it as `MIX_ENV=test mix ash_quint.promote`
  when `ash_quint` is a test-only dependency.
  """

  use Mix.Task

  alias AshQuint.Config
  alias AshQuint.Gen
  alias AshQuint.ITF
  alias AshQuint.Manifest

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(argv) do
    {_opts, files} = OptionParser.parse!(argv, strict: [])
    if files == [], do: Mix.raise("usage: mix ash_quint.promote <candidate> ...")

    config = Config.load!()

    promotions =
      files
      |> Enum.reduce([], fn file, acc -> [check!(config, file, acc) | acc] end)
      |> Enum.reverse()

    promotions
    |> Enum.group_by(& &1.model.name)
    |> Enum.sort_by(fn {name, _promotions} -> name end)
    |> Enum.each(fn {_name, [first | _] = promotions} -> write!(first, promotions) end)

    Enum.each(promotions, fn promotion ->
      Mix.shell().info(
        "ash_quint.promote: #{promotion.model.name}: added #{promotion.entry.file} " <>
          "(#{promotion.entry.steps} steps)"
      )
    end)
  end

  # Everything is checked, and the entry built, before anything is written.
  defp check!(config, file, earlier) do
    binary = read!(file)
    provenance = provenance!(file, binary)
    model = model!(config, file, provenance["model"])
    manifest = manifest!(config, file, model)
    check_hash!(config, file, model, manifest, provenance)

    name = Gen.regression_file(provenance["seed"], provenance["index"])
    target = Path.join(model.out, name)

    if File.exists?(Path.join(config.root, target)) or
         Enum.any?(earlier, &(&1.target == target)) do
      Mix.raise("#{file}: #{target} already exists")
    end

    if Enum.any?(manifest.traces, &(&1.file == name)) do
      Mix.raise(
        "#{file}: #{name} is already in #{Path.join(model.out, "manifest.json")}; " <>
          "run MIX_ENV=test mix ash_quint.gen #{model.name} to drop entries whose files are gone"
      )
    end

    %{
      model: model,
      root: config.root,
      manifest: manifest,
      target: target,
      binary: binary,
      entry: entry!(file, name, binary, model)
    }
  end

  defp read!(file) do
    case File.read(file) do
      {:ok, binary} -> binary
      {:error, reason} -> Mix.raise("#{file}: could not read it (#{:file.format_error(reason)})")
    end
  end

  defp model!(config, file, name) do
    [model] = Config.select!(config, [name])
    model
  rescue
    error in Mix.Error -> Mix.raise("#{file}: " <> Exception.message(error))
  end

  defp provenance!(file, binary) do
    case Gen.provenance(binary) do
      {:ok, %{"model" => model, "seed" => seed, "index" => index} = provenance}
      when is_binary(model) and is_integer(seed) and is_integer(index) ->
        provenance

      _other ->
        Mix.raise("#{file}: not an ash_quint explore candidate")
    end
  end

  defp check_hash!(config, file, model, manifest, provenance) do
    current = Manifest.hash_file(Path.join(config.root, model.model))

    unless provenance["model_hash"] == current and
             Map.get(manifest.models, model.model) == current do
      Mix.raise(
        "#{file} was found against another version of #{model.model}; " <>
          "run MIX_ENV=test mix ash_quint.gen #{model.name} and explore again"
      )
    end
  end

  defp entry!(file, name, binary, model) do
    Gen.regression_entry!(name, binary, model)
  rescue
    error in [ArgumentError, ITF.Error] -> Mix.raise("#{file}: " <> Exception.message(error))
  end

  defp manifest!(config, file, model) do
    case Manifest.load(config, model, need: :interface) do
      {:ok, manifest} -> manifest
      {:error, message} -> Mix.raise("#{file}: " <> message)
    end
  end

  defp write!(%{root: root, model: model, manifest: manifest}, promotions) do
    Enum.each(promotions, &File.write!(Path.join(root, &1.target), &1.binary))
    traces = manifest.traces ++ Enum.map(promotions, & &1.entry)
    path = Path.join([root, model.out, "manifest.json"])
    File.write!(path, Manifest.encode(%{manifest | traces: traces}))
  end
end
