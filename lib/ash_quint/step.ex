defmodule AshQuint.Step do
  @moduledoc """
  One replayable step, built from a decoded trace state.

    * `action_taken` — the tag of the action variant at `action_path`
      (default `["lastAction"]`).
    * `nondet_picks` — the variant's value: a record stays a map, the unit
      value becomes `%{}`, and any other value `v` (a set included) becomes
      `%{"value" => v}`. A Quint `Map` decodes to a map like a record does,
      so it is taken as the record's fields: wrap it in a record
      (`Act({ m: m })`) to keep it whole.
    * `result` — `:accepted` for `Accepted`, `{:rejected, code}` for
      `Rejected(code)`, or `nil` when the trace has nothing at `result_path`
      (default `["lastResult"]`).
    * `state` — every other variable: the state without the top-level
      variables that `action_path` and `result_path` start with.
  """

  @enforce_keys [:index, :action_taken, :nondet_picks, :result, :state]
  defstruct [:index, :action_taken, :nondet_picks, :result, :state]

  @type result :: :accepted | {:rejected, String.t()} | nil

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          action_taken: String.t(),
          nondet_picks: map(),
          result: result(),
          state: map()
        }

  @type option :: {:action_path, [String.t(), ...]} | {:result_path, [String.t(), ...]}

  @doc """
  Builds the step for the state at `index`. Returns `{:error, reason}` when
  the action is missing or not a variant, or the result isn't `Accepted` or
  `Rejected(str)`.
  """
  @spec from_state(map(), non_neg_integer(), [option()]) :: {:ok, t()} | {:error, String.t()}
  def from_state(state, index, opts) do
    action_path = Keyword.get(opts, :action_path, ["lastAction"])
    result_path = Keyword.get(opts, :result_path, ["lastResult"])

    with {:ok, tag, picks} <- action(state, action_path),
         {:ok, result} <- result(state, result_path) do
      {:ok,
       %__MODULE__{
         index: index,
         action_taken: tag,
         nondet_picks: picks,
         result: result,
         state: Map.drop(state, [hd(action_path), hd(result_path)])
       }}
    end
  end

  @doc """
  The label of a step result, as the manifest records it and
  `mix ash_quint.coverage` prints it: `"accepted"` for `Accepted`,
  `"rejected:" <> code` for `Rejected(code)` (so `Rejected("over_limit")`
  is `"rejected:over_limit"`), and `nil` for a step without a result.
  """
  @spec result_label(result()) :: String.t() | nil
  def result_label(:accepted), do: "accepted"
  def result_label({:rejected, code}), do: "rejected:" <> code
  def result_label(nil), do: nil

  defp action(state, path) do
    case fetch_path(state, path) do
      {:ok, {:variant, tag, value}} -> {:ok, tag, picks(value)}
      {:ok, other} -> {:error, "action at #{label(path)} is not a variant: #{inspect(other)}"}
      :error -> {:error, "no action at #{label(path)}"}
    end
  end

  defp picks(record) when is_map(record) and not is_struct(record), do: record
  defp picks({}), do: %{}
  defp picks(value), do: %{"value" => value}

  defp result(state, path) do
    case fetch_path(state, path) do
      :error ->
        {:ok, nil}

      {:ok, {:variant, "Accepted", {}}} ->
        {:ok, :accepted}

      {:ok, {:variant, "Rejected", code}} when is_binary(code) ->
        {:ok, {:rejected, code}}

      {:ok, other} ->
        {:error,
         "result at #{label(path)} must be Accepted or Rejected(str), got #{inspect(other)}"}
    end
  end

  defp fetch_path(value, []), do: {:ok, value}

  defp fetch_path(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> fetch_path(value, rest)
      :error -> :error
    end
  end

  defp fetch_path(_value, _path), do: :error

  defp label(path), do: Enum.join(path, ".")
end
