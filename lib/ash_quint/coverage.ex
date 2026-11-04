defmodule AshQuint.Coverage do
  @moduledoc """
  Action × outcome coverage of a model's traces, from its manifest: the
  logic behind `mix ash_quint.coverage` and the table `mix ash_quint.gen`
  prints after writing.

  For each action taken in the traces, the coverage counts its steps and,
  per result label (`AshQuint.Step.result_label/1`: `"accepted"` or
  `"rejected:<code>"`), the steps with that result. A table of it:

      counter: 9 traces, 53 steps
        Inc    23  accepted 20  rejected:over_limit 3
        Peek   20  accepted 20
        Reset  10  accepted 10

  An outcome missing from an action's row is one no trace reaches. For a
  model without results the rows have the step counts only; steps without
  a result in a model that has some show as `no result <n>`.

  Only actions the traces take are listed: an action the model has but no
  trace takes doesn't appear (the manifest doesn't know the model's
  actions).
  """

  alias AshQuint.Manifest

  @type row :: %{
          action: String.t(),
          steps: pos_integer(),
          outcomes: %{String.t() => pos_integer()},
          no_result: non_neg_integer()
        }

  @type t :: %{traces: non_neg_integer(), steps: non_neg_integer(), rows: [row()]}

  @doc """
  The coverage of `manifest`'s traces, with rows sorted by action. Returns
  `{:error, :no_outcomes}` for a manifest written before outcomes were
  recorded (format version 1): regenerate it with `mix ash_quint.gen`.
  """
  @spec from_manifest(Manifest.t()) :: {:ok, t()} | {:error, :no_outcomes}
  def from_manifest(%Manifest{traces: traces}) do
    if Enum.any?(traces, &is_nil(&1.outcomes)) do
      {:error, :no_outcomes}
    else
      {:ok, tally(traces)}
    end
  end

  defp tally(traces) do
    actions = traces |> Enum.map(& &1.actions) |> Enum.reduce(%{}, &merge_counts/2)

    outcomes =
      Enum.reduce(traces, %{}, fn trace, acc ->
        Map.merge(acc, trace.outcomes, fn _action, a, b -> merge_counts(a, b) end)
      end)

    rows =
      actions
      |> Enum.sort()
      |> Enum.map(fn {action, steps} ->
        labels = Map.get(outcomes, action, %{})

        %{
          action: action,
          steps: steps,
          outcomes: labels,
          no_result: steps - Enum.sum(Map.values(labels))
        }
      end)

    %{traces: length(traces), steps: Enum.sum(Enum.map(traces, & &1.steps)), rows: rows}
  end

  defp merge_counts(a, b), do: Map.merge(a, b, fn _key, x, y -> x + y end)

  @doc """
  Formats `coverage` as lines of a table headed by `name`: one row per
  action, with its step count and then each outcome label and count,
  sorted by label. `no result <n>` is shown only when some step of the
  model has a result.
  """
  @spec format(String.t(), t()) :: [String.t()]
  def format(name, %{traces: traces, steps: steps, rows: rows}) do
    header = "#{name}: #{plural(traces, "trace")}, #{plural(steps, "step")}"
    results? = Enum.any?(rows, &(&1.outcomes != %{}))
    action_width = rows |> Enum.map(&String.length(&1.action)) |> Enum.max(fn -> 0 end)
    steps_width = rows |> Enum.map(&digits(&1.steps)) |> Enum.max(fn -> 0 end)

    lines =
      Enum.map(rows, fn row ->
        cells =
          Enum.map(Enum.sort(row.outcomes), fn {label, count} -> "#{label} #{count}" end) ++
            if results? and row.no_result > 0, do: ["no result #{row.no_result}"], else: []

        [
          "  ",
          String.pad_trailing(row.action, action_width),
          "  ",
          String.pad_leading(Integer.to_string(row.steps), steps_width)
          | Enum.map(cells, &["  ", &1])
        ]
        |> IO.iodata_to_binary()
      end)

    [header | lines]
  end

  defp digits(n), do: n |> Integer.to_string() |> String.length()

  defp plural(1, noun), do: "1 #{noun}"
  defp plural(n, noun), do: "#{n} #{noun}s"
end
