defmodule Mix.Tasks.AshQuint.Gen do
  @shortdoc "Generates committed Quint traces and their manifest"

  @moduledoc """
  Generates each model's traces with Quint and writes them, with their
  manifest, to the model's `out` directory.

      mix ash_quint.gen [model ...] [--check] [--dry-run]

  Reads `ash_quint.exs` in the current directory and runs every configured
  model, or only the models named. See `AshQuint.Gen` for the Quint
  commands: after a model's traces, `quint compile --target=json` reads
  the model's interface (its actions, results and variables; see
  `AshQuint.Interface`), which the manifest records.

    * Without flags, replaces the `*.itf.json` files and `manifest.json` in
      each model's `out` directory. Other files there are left alone.
    * `--dry-run` prints the files that would be added, changed or removed,
      and writes nothing.
    * `--check` prints the same, and exits with status 1 if anything would
      change.

  After writing a model's traces, prints its action × outcome table (see
  `mix ash_quint.coverage`), so a regeneration shows at once which
  outcomes the new traces reach. `--check` and `--dry-run` print only
  the file changes.

  Nothing is written unless every model generates. Quint failing or not
  being runnable, a failing scenario, a witness not reached, a random run
  or a compile exiting non-zero all raise with Quint's output, as does an
  interface that can't be read from the compiled model.

  `ash_quint` is usually a test-only dependency, so run the task as
  `MIX_ENV=test mix ash_quint.gen`, or add
  `def cli, do: [preferred_envs: ["ash_quint.gen": :test]]` to `mix.exs`.
  """

  use Mix.Task

  alias AshQuint.Config
  alias AshQuint.Coverage
  alias AshQuint.Gen
  alias AshQuint.Manifest

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(argv) do
    {opts, names} = OptionParser.parse!(argv, strict: [check: :boolean, dry_run: :boolean])
    config = Config.load!()
    models = Config.select!(config, names)

    generated =
      case Gen.generate(config, models) do
        {:ok, generated} -> generated
        {:error, message} -> Mix.raise(message)
      end

    if opts[:check] || opts[:dry_run] do
      report(config, models, generated, opts[:check])
    else
      Enum.each(models, fn model ->
        result = Map.fetch!(generated, model.name)
        Gen.write!(Path.join(config.root, model.out), result)

        Mix.shell().info(
          "ash_quint.gen: #{model.name}: wrote #{map_size(result.files)} traces to #{model.out}"
        )

        print_coverage(model, result)
      end)
    end
  end

  defp print_coverage(model, result) do
    manifest = Manifest.decode!(result.manifest, Path.join(model.out, "manifest.json"))
    {:ok, coverage} = Coverage.from_manifest(manifest, init_action: model.init_action)
    Enum.each(Coverage.format(Atom.to_string(model.name), coverage), &Mix.shell().info(&1))
  end

  defp report(config, models, generated, check?) do
    changed? =
      Enum.reduce(models, false, fn model, changed? ->
        diff = Gen.diff(Path.join(config.root, model.out), Map.fetch!(generated, model.name))
        lines = diff_lines(diff)

        if lines != [] do
          Mix.shell().info("ash_quint.gen: #{model.name} (#{model.out}):")
          Enum.each(lines, &Mix.shell().info(&1))
        end

        changed? or lines != []
      end)

    cond do
      not changed? -> Mix.shell().info("ash_quint.gen: traces are current")
      check? -> exit({:shutdown, 1})
      true -> :ok
    end
  end

  defp diff_lines(diff) do
    Enum.map(diff.added, &"  add #{&1}") ++
      Enum.map(diff.changed, &"  change #{&1}") ++
      Enum.map(diff.removed, &"  remove #{&1}")
  end
end
