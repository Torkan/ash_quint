defmodule AshQuint.Test.TraceBuilder do
  @moduledoc false
  # Hand-built traces of the toy counter model, in decoded (Elixir) shape.

  alias AshQuint.Trace

  @accepted {:variant, "Accepted", {}}

  @doc """
  A `%Trace{name: "t", source: :random, seed: 7, path: "toy"}` of `states`.
  `results: false` drops `lastResult` from every state.
  """
  def trace(states, opts \\ []) do
    states =
      if Keyword.get(opts, :results, true),
        do: states,
        else: Enum.map(states, &Map.delete(&1, "lastResult"))

    vars = states |> Enum.flat_map(&Map.keys/1) |> Enum.uniq() |> Enum.sort()
    %Trace{name: "t", source: :random, seed: 7, path: "toy", vars: vars, states: states}
  end

  def init(count \\ 0), do: state(count, {:variant, "Init", {}})

  def inc(count, by, result \\ :accepted),
    do: state(count, {:variant, "Inc", %{"by" => by}}, result)

  def reset(count \\ 0), do: state(count, {:variant, "Reset", {}})
  def peek(count, result \\ :accepted), do: state(count, {:variant, "Peek", {}}, result)
  def begin(count, by), do: state(count, {:variant, "Begin", by})
  def commit(count, result \\ :accepted), do: state(count, {:variant, "Commit", {}}, result)

  def inc_start(count, op, by),
    do: state(count, {:variant, "IncStart", %{"op" => op, "by" => by}}, :pending)

  def inc_advance(count, op), do: state(count, {:variant, "IncRead", %{"op" => op}}, :pending)

  def inc_done(count, op, result \\ :accepted),
    do: state(count, {:variant, "IncDone", %{"op" => op}}, result)

  def wait_op(count, op), do: state(count, {:variant, "WaitOp", %{"op" => op}})

  defp state(count, action, result \\ :accepted) do
    %{"count" => count, "lastAction" => action, "lastResult" => result(result)}
  end

  defp result(:accepted), do: @accepted
  defp result({:rejected, code}), do: {:variant, "Rejected", code}
  defp result(:pending), do: {:variant, "Pending", {}}
end

defmodule AshQuint.Test.ToyAdapter do
  @moduledoc false
  # An in-memory counter whose state lives in ctx. An inc is rejected with
  # "too_big" when the count would exceed 3. `faults:` breaks it on purpose:
  #
  #   :off_by_one         inc adds by + 1
  #   :wrong_code         rejects with "other"
  #   :crash              inc returns {:error, %RuntimeError{message: "db down"}}
  #   :negative           reset sets -1
  #   :bad_return         inc returns :ok instead of a step/2 shape
  #   :extra_key          the projection also has "ghost" => 1
  #   :invariant_raises   the non_negative invariant raises
  use AshQuint.Adapter

  alias AshQuint.Step

  @limit 3

  @impl true
  def init(_trace, opts) do
    {:ok, %{count: 0, pending: nil, faults: Keyword.get(opts, :faults, [])}}
  end

  @impl true
  def step(ctx, %Step{action_taken: "Inc", nondet_picks: %{"by" => by}}), do: inc(ctx, by)
  def step(ctx, %Step{action_taken: "Peek"}), do: {:skip, ctx}

  def step(ctx, %Step{action_taken: "Begin", nondet_picks: %{"value" => by}}),
    do: {:pending, %{ctx | pending: by}}

  def step(%{pending: by} = ctx, %Step{action_taken: "Commit"}) when is_integer(by),
    do: inc(%{ctx | pending: nil}, by)

  def step(ctx, %Step{action_taken: "Reset"}) do
    count = if :negative in ctx.faults, do: -1, else: 0
    {:ok, {:ok, count}, %{ctx | count: count}}
  end

  defp inc(ctx, by) do
    cond do
      :bad_return in ctx.faults ->
        :ok

      :crash in ctx.faults ->
        {:ok, {:error, %RuntimeError{message: "db down"}}, ctx}

      ctx.count + by > @limit ->
        code = if :wrong_code in ctx.faults, do: "other", else: "too_big"
        {:ok, {:rejected, code}, ctx}

      true ->
        added = if :off_by_one in ctx.faults, do: by + 1, else: by
        count = ctx.count + added
        {:ok, {:ok, count}, %{ctx | count: count}}
    end
  end

  @impl true
  def project(ctx) do
    projected = %{"count" => ctx.count}
    if :extra_key in ctx.faults, do: Map.put(projected, "ghost", 1), else: projected
  end

  @impl true
  def outcome({:ok, _}), do: :accepted
  def outcome({:rejected, code}), do: {:rejected, code}
  def outcome({:error, error}), do: {:failed, Exception.message(error)}

  @impl true
  def invariants do
    [
      non_negative: fn projected, ctx ->
        cond do
          :invariant_raises in ctx.faults -> raise "invariant blew up"
          projected["count"] >= 0 -> :ok
          true -> {:error, "count is #{projected["count"]}"}
        end
      end
    ]
  end
end

defmodule AshQuint.Test.ToyAdapterNoReset do
  @moduledoc false
  # The toy adapter without a step/2 clause for "Reset".
  use AshQuint.Adapter

  alias AshQuint.Step
  alias AshQuint.Test.ToyAdapter

  @impl true
  defdelegate init(trace, opts), to: ToyAdapter

  @impl true
  def step(ctx, %Step{action_taken: action} = step) when action != "Reset",
    do: ToyAdapter.step(ctx, step)

  @impl true
  defdelegate project(ctx), to: ToyAdapter

  @impl true
  defdelegate outcome(result), to: ToyAdapter
end

defmodule AshQuint.Test.ToyAdapterMissingKey do
  @moduledoc false
  # The toy adapter whose expected/2 leaves out the projected "count".
  use AshQuint.Adapter

  alias AshQuint.Test.ToyAdapter

  @impl true
  defdelegate init(trace, opts), to: ToyAdapter

  @impl true
  defdelegate step(ctx, step), to: ToyAdapter

  @impl true
  defdelegate project(ctx), to: ToyAdapter

  @impl true
  def expected(_ctx, _step), do: %{}

  @impl true
  defdelegate outcome(result), to: ToyAdapter
end

defmodule AshQuint.Test.ToyAdapterBlindReset do
  @moduledoc false
  # The toy adapter whose expected/2 takes a Reset's count from the system
  # instead of the model, so a dropped Reset goes unnoticed.
  use AshQuint.Adapter

  alias AshQuint.Step
  alias AshQuint.Test.ToyAdapter

  @impl true
  defdelegate init(trace, opts), to: ToyAdapter

  @impl true
  defdelegate step(ctx, step), to: ToyAdapter

  @impl true
  defdelegate project(ctx), to: ToyAdapter

  @impl true
  def expected(ctx, %Step{action_taken: "Reset"}), do: %{"count" => ctx.count}
  def expected(_ctx, %Step{state: state}), do: Map.take(state, ["count"])

  @impl true
  defdelegate outcome(result), to: ToyAdapter
end

defmodule AshQuint.Test.ToyAdapterLimit do
  @moduledoc false
  # The toy adapter that also projects the constant "limit" (3).
  use AshQuint.Adapter

  alias AshQuint.Step
  alias AshQuint.Test.ToyAdapter

  @impl true
  defdelegate init(trace, opts), to: ToyAdapter

  @impl true
  defdelegate step(ctx, step), to: ToyAdapter

  @impl true
  def project(ctx), do: Map.put(ToyAdapter.project(ctx), "limit", 3)

  @impl true
  def expected(_ctx, %Step{state: state}), do: %{"count" => state["count"], "limit" => 3}

  @impl true
  defdelegate outcome(result), to: ToyAdapter
end

defmodule AshQuint.Test.ToyAdapterConstant do
  @moduledoc false
  # The toy adapter that projects only the constant "limit" (3), so no key
  # and no call is ever shown to change the state.
  use AshQuint.Adapter

  alias AshQuint.Test.ToyAdapter

  @impl true
  defdelegate init(trace, opts), to: ToyAdapter

  @impl true
  defdelegate step(ctx, step), to: ToyAdapter

  @impl true
  def project(_ctx), do: %{"limit" => 3}

  @impl true
  def expected(_ctx, _step), do: %{"limit" => 3}

  @impl true
  defdelegate outcome(result), to: ToyAdapter
end

defmodule AshQuint.Test.ToyAdapterCounts do
  @moduledoc false
  # The toy adapter that projects its count as counter "c07" of twelve, the
  # others 0, under the key "counts": a long map for the key mismatch diff.
  # `counts/1` builds the model's value for a count.
  use AshQuint.Adapter

  alias AshQuint.Test.ToyAdapter

  @impl true
  defdelegate init(trace, opts), to: ToyAdapter

  @impl true
  defdelegate step(ctx, step), to: ToyAdapter

  @impl true
  def project(ctx), do: %{"counts" => counts(ctx.count)}

  @impl true
  defdelegate outcome(result), to: ToyAdapter

  @doc "Twelve counters `c01`…`c12`, all 0 but `c07`, which is `count`."
  def counts(count) do
    Map.new(1..12, fn i ->
      name = "c" <> String.pad_leading(Integer.to_string(i), 2, "0")
      {name, if(i == 7, do: count, else: 0)}
    end)
  end

  @doc "`state` with the model's `counts` for its `count`."
  def with_counts(state), do: Map.put(state, "counts", counts(state["count"]))
end
