defmodule Mix.Tasks.AshQuint.Gen.Adapter do
  @shortdoc "Scaffolds an adapter and its test module from a model's manifest"

  @moduledoc """
  Writes an adapter skeleton and its test module for one model, from the
  model interface recorded in its manifest.

      MIX_ENV=test mix ash_quint.gen.adapter <model> [--adapter Module] [--force]

  Reads `ash_quint.exs` in the current directory and the model's
  `<out>/manifest.json` only: Quint isn't run. It writes:

    * `test/support/<model>_trace.ex`, the adapter, module
      `<App>.<Model>Trace` (the project's app and the model's name
      camelized), or `--adapter`;
    * `test/<model>_trace_test.exs`, its test module, `<adapter>Test`.

  An existing file is overwritten only when you say yes, or with `--force`.
  The adapter compiles without warnings and every replay fails at its
  first step with `<adapter>: <what> is not implemented yet`, until each
  `todo!/1` is replaced. See `AshQuint.Scaffold` for what the files
  contain.

  It is an error when the manifest is missing or older than format 3
  (written before the model interface was recorded): run
  `mix ash_quint.gen <model>` first.
  """

  use Mix.Task

  alias AshQuint.{Config, Manifest, Scaffold}

  @usage "usage: mix ash_quint.gen.adapter <model> [--adapter Module] [--force]"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(argv) do
    {opts, names} = OptionParser.parse!(argv, strict: [adapter: :string, force: :boolean])

    name =
      case names do
        [name] -> name
        _other -> Mix.raise(@usage)
      end

    config = Config.load!()
    [model] = Config.select!(config, [name])
    manifest = read_manifest!(config, model)

    adapter =
      case opts[:adapter] do
        nil -> default_adapter(model)
        module -> Module.concat([module])
      end

    test_module = Module.concat([inspect(adapter) <> "Test"])
    force = Keyword.get(opts, :force, false)

    Mix.Generator.create_file(
      "test/support/#{name}_trace.ex",
      Scaffold.adapter_source(adapter, manifest, model),
      force: force
    )

    Mix.Generator.create_file(
      "test/#{name}_trace_test.exs",
      Scaffold.test_source(test_module, adapter, manifest, model),
      force: force
    )

    :ok
  end

  defp read_manifest!(config, model) do
    path = Path.join(model.out, "manifest.json")
    regenerate = "run MIX_ENV=test mix ash_quint.gen #{model.name}"

    unless File.regular?(Path.join(config.root, path)) do
      Mix.raise("no manifest for #{inspect(model.name)} at #{path}; #{regenerate}")
    end

    case Manifest.read!(Path.join(config.root, path)) do
      %Manifest{interface: nil, version: version} ->
        Mix.raise("#{path} has no model interface (manifest format #{version}); #{regenerate}")

      manifest ->
        manifest
    end
  end

  defp default_adapter(model) do
    app =
      case Mix.Project.config()[:app] do
        nil -> Mix.raise("not in a Mix project with an app; pass --adapter Module")
        app -> app
      end

    Module.concat([
      Macro.camelize(Atom.to_string(app)),
      Macro.camelize(Atom.to_string(model.name)) <> "Trace"
    ])
  end
end
