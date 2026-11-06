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
      `Rejected(code)`, `:pending` for the `pending_result` variant (default
      `Pending`), or `nil` when the trace has nothing at `result_path`
      (default `["lastResult"]`). A `Pending` step starts or advances a call
      that stays in flight; the step that completes it has its outcome.
    * `op` — the operation id: the string at `op_field` (default `"op"`) in
      the picks (`IncStart({ op: "o1", by: 2 })` gives `"o1"`), or `nil`
      when there is no such string. It is also left in `nondet_picks`. A
      pending step must have one.
    * `state` — every other variable: the state without the top-level
      variables that `action_path` and `result_path` start with.
  """

  @enforce_keys [:index, :action_taken, :nondet_picks, :result, :state]
  defstruct [:index, :action_taken, :nondet_picks, :result, :state, op: nil]

  @type result :: :accepted | {:rejected, String.t()} | :pending | nil

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          action_taken: String.t(),
          nondet_picks: map(),
          result: result(),
          op: String.t() | nil,
          state: map()
        }

  @type option ::
          {:action_path, [String.t(), ...]}
          | {:result_path, [String.t(), ...]}
          | {:pending_result, String.t()}
          | {:op_field, String.t()}

  @action_path ["lastAction"]
  @result_path ["lastResult"]

  @doc """
  Builds the step for the state at `index`. Returns `{:error, reason}` when
  the action is missing or not a variant, the result isn't `Accepted`,
  `Rejected(str)` or the pending variant, or a pending step has no string op field.
  """
  @spec from_state(map(), non_neg_integer(), [option()]) :: {:ok, t()} | {:error, String.t()}
  def from_state(state, index, opts) do
    action_path = Keyword.get(opts, :action_path, @action_path)
    result_path = Keyword.get(opts, :result_path, @result_path)
    pending = Keyword.get(opts, :pending_result, "Pending")
    op_field = Keyword.get(opts, :op_field, "op")

    with {:ok, tag, picks} <- action(state, action_path),
         {:ok, result} <- result(state, result_path, pending),
         {:ok, op} <- op(picks, op_field, result, action_path) do
      {:ok,
       %__MODULE__{
         index: index,
         action_taken: tag,
         nondet_picks: picks,
         result: result,
         op: op,
         state: Map.drop(state, roots(opts))
       }}
    end
  end

  @doc """
  The step options (`t:option/0`) among `opts`, such as
  `AshQuint.Replay.run/3`'s.
  """
  @spec options(keyword()) :: [option()]
  def options(opts),
    do: Keyword.take(opts, [:action_path, :result_path, :pending_result, :op_field])

  @doc """
  The top-level variables that `action_path` and `result_path` in `opts`
  start with (by default `"lastAction"` and `"lastResult"`): the ones a
  step's `state` leaves out.
  """
  @spec roots(keyword()) :: [String.t()]
  def roots(opts) do
    [
      hd(Keyword.get(opts, :action_path, @action_path)),
      hd(Keyword.get(opts, :result_path, @result_path))
    ]
  end

  @doc """
  The label of a step result, as the manifest records it and
  `mix ash_quint.coverage` prints it: `"accepted"` for `Accepted`,
  `"rejected:" <> code` for `Rejected(code)` (so `Rejected("over_limit")`
  is `"rejected:over_limit"`), `"pending"` for a step that keeps its call
  in flight (whatever `pending_result` is named), and `nil` for a step
  without a result.
  """
  @spec result_label(result()) :: String.t() | nil
  def result_label(:accepted), do: "accepted"
  def result_label({:rejected, code}), do: "rejected:" <> code
  def result_label(:pending), do: "pending"
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

  defp result(state, path, pending) do
    case fetch_path(state, path) do
      :error ->
        {:ok, nil}

      {:ok, {:variant, ^pending, {}}} ->
        {:ok, :pending}

      {:ok, {:variant, "Accepted", {}}} ->
        {:ok, :accepted}

      {:ok, {:variant, "Rejected", code}} when is_binary(code) ->
        {:ok, {:rejected, code}}

      {:ok, other} ->
        {:error,
         "result at #{label(path)} must be Accepted, Rejected(str) or #{pending}, " <>
           "got #{inspect(other)}"}
    end
  end

  # A Pending step must name its op; elsewhere a field that isn't a string
  # is just a pick, as it was before ops existed.
  defp op(picks, field, result, action_path) do
    case {Map.fetch(picks, field), result} do
      {{:ok, op}, _result} when is_binary(op) ->
        {:ok, op}

      {_other, :pending} ->
        {:error,
         "the action at #{label(action_path)} is pending but has no string op field " <>
           "#{inspect(field)}: #{inspect(picks)}"}

      {_other, _result} ->
        {:ok, nil}
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
