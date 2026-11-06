defmodule Mix.Tasks.AshQuint.Coverage do
  @shortdoc "Prints which outcomes each model action reaches in the committed traces"

  @moduledoc """
  Prints, for each model, which outcomes each action reaches across its
  committed traces, read from the model's `manifest.json`.

      mix ash_quint.coverage [model ...]

  Reads `ash_quint.exs` in the current directory and reports every
  configured model, or only the models named. It reads the committed
  manifests only: it needs neither Node nor Quint. See
  `AshQuint.Coverage` for the table:

      counter: 9 traces, 53 steps
        Inc    23  accepted 20  rejected:over_limit 3
        Peek   20  accepted 20
        Reset  10  accepted 10

  Every model action but the model's `init_action` has a row, with 0
  steps when no trace takes it. A format 2 manifest, written before the
  model's actions were recorded, lists only the actions the traces take
  and ends with a note asking for a regeneration.

  A model whose manifest is missing, invalid or written before outcomes
  were recorded is an error asking you to regenerate it with
  `mix ash_quint.gen`; the other models' tables are printed first.

  Like `mix ash_quint.gen`, run it as `MIX_ENV=test mix ash_quint.coverage`
  when `ash_quint` is a test-only dependency.
  """

  use Mix.Task

  alias AshQuint.Config
  alias AshQuint.Coverage
  alias AshQuint.Manifest

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(argv) do
    {_opts, names} = OptionParser.parse!(argv, strict: [])
    config = Config.load!()

    errors =
      config
      |> Config.select!(names)
      |> Enum.flat_map(fn model ->
        case coverage(config, model) do
          {:ok, coverage} ->
            Enum.each(
              Coverage.format(Atom.to_string(model.name), coverage),
              &Mix.shell().info(&1)
            )

            []

          {:error, message} ->
            [message]
        end
      end)

    if errors != [], do: Mix.raise(Enum.join(errors, "\n"))
    :ok
  end

  defp coverage(config, model) do
    path = Path.join(model.out, "manifest.json")
    regen = "run MIX_ENV=test mix ash_quint.gen #{model.name}"

    with {:ok, binary} <- read(config, path, model, regen),
         {:ok, manifest} <- decode(binary, path, regen) do
      case Coverage.from_manifest(manifest, init_action: model.init_action) do
        {:ok, coverage} ->
          {:ok, coverage}

        {:error, :no_outcomes} ->
          {:error,
           "#{model.name}: #{path} was written before ash_quint recorded outcomes " <>
             "(manifest format 1); #{regen} to regenerate it"}
      end
    end
  end

  defp read(config, path, model, regen) do
    case File.read(Path.join(config.root, path)) do
      {:ok, binary} ->
        {:ok, binary}

      {:error, reason} ->
        {:error,
         "#{model.name}: no manifest at #{path} (#{:file.format_error(reason)}); #{regen}"}
    end
  end

  defp decode(binary, path, regen) do
    {:ok, Manifest.decode!(binary, path)}
  rescue
    error in ArgumentError -> {:error, Exception.message(error) <> "; " <> regen}
  end
end
