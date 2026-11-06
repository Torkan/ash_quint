defmodule AshQuint.Shrink.Loop do
  @moduledoc false

  # Internal: the state machine of AshQuint.Shrink's loop, mapped 1:1 to
  # the Quint model in models/practices/model.qnt (module shrink). The
  # oracles of the model (Quint's guards and the replay) live outside: the
  # driver asks `removals/1` for a round's reductions, runs and replays
  # them, and hands the first accepted one (or nil) to `advance/2`.
  #
  # `kept` are the candidate's step positions behind the current trace
  # (position k is trace step k + 1; the initial state is never removed);
  # the last one is the failing step, always kept. The others are the
  # prefix.

  @enforce_keys [:kept, :chunk, :budget]
  defstruct kept: [], chunk: 1, rounds: 0, budget: 1, done: false, exhausted: false

  @type t :: %__MODULE__{
          kept: [non_neg_integer()],
          chunk: pos_integer(),
          rounds: non_neg_integer(),
          budget: pos_integer(),
          done: boolean(),
          exhausted: boolean()
        }

  @doc """
  The loop over a candidate of `n` steps, within `budget` rounds (the
  model's `initWith`): every position kept, the chunk half the prefix,
  done at once for a single step.
  """
  @spec new(pos_integer(), pos_integer()) :: t()
  def new(n, budget) when is_integer(n) and n > 0 and is_integer(budget) and budget > 0 do
    %__MODULE__{kept: Enum.to_list(0..(n - 1)), chunk: half(n - 1), budget: budget, done: n <= 1}
  end

  @doc """
  The round's reductions (the model's `starts` and `removeChunk`): for each
  start `p` = 0, chunk, 2·chunk, … below the prefix length, `{p, kept}`
  with the prefix positions `p..p + chunk - 1` removed, in order of `p`.
  """
  @spec removals(t()) :: [{non_neg_integer(), [non_neg_integer()]}]
  def removals(%__MODULE__{kept: kept, chunk: chunk}) do
    prefix = length(kept) - 1

    0
    |> Stream.iterate(&(&1 + chunk))
    |> Enum.take_while(&(&1 < prefix))
    |> Enum.map(fn p ->
      upto = min(p + chunk, prefix)
      {p, Enum.take(kept, p) ++ Enum.drop(kept, upto)}
    end)
  end

  @doc """
  One round (the model's `round`), given the accepted reduction, which ends
  with a kept position, or `nil` when nothing was accepted.

  The loop ends by itself when the new prefix is empty or a round at chunk 1
  accepts nothing, and exhausted when the budget runs out first. An
  accepted round keeps the chunk, narrowed to half the new prefix when
  wider; a failed one halves it.
  """
  @spec advance(t(), [non_neg_integer()] | nil) :: t()
  def advance(%__MODULE__{done: false} = loop, accepted) do
    rounds = loop.rounds + 1
    budget = rounds >= loop.budget

    {kept, chunk, natural} =
      case accepted do
        nil ->
          {loop.kept, half(loop.chunk), loop.chunk == 1}

        [_ | _] ->
          prefix = length(accepted) - 1
          chunk = if loop.chunk > prefix, do: half(prefix), else: loop.chunk
          {accepted, chunk, prefix == 0}
      end

    %{
      loop
      | kept: kept,
        chunk: chunk,
        rounds: rounds,
        done: natural or budget,
        exhausted: budget and not natural
    }
  end

  defp half(c), do: max(1, div(c, 2))
end
