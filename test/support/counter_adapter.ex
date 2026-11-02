defmodule AshQuint.Test.CounterAdapter do
  @moduledoc """
  The reference adapter: replays the counter example
  (`priv/examples/counter`) against the ETS-backed `AshQuint.Test.Counter`
  resource.

    * The model's counter names (`"c1"`, `"c2"`) become row ids through
      `AshQuint.Names`; a counter's row is opened on its first `Inc`.
    * `Inc({ctr, by})` and `Reset(ctr)` run the resource's `:inc` and
      `:reset` actions; `Peek` is model-only, so it is skipped and only the
      state is compared.
    * `outcome/1` maps `AshQuint.Test.Rejected` to the model's
      `Rejected(code)`.
    * `project/1` reads the rows this trace opened (so other traces' rows
      in the same table don't leak in) as the model's `counts` and `writes`
      maps.
    * `invariants/0` mirrors the model's `countsWithinLimit` and
      `writesNonNegative`.
  """
  use AshQuint.Adapter

  alias AshQuint.{Names, Step}
  alias AshQuint.Test.{Counter, Rejected}

  @limit 3

  @impl true
  def init(_trace, _opts), do: {:ok, %{ids: MapSet.new()}}

  @impl true
  def step(ctx, %Step{action_taken: "Inc", nondet_picks: %{"ctr" => ctr, "by" => by}}) do
    {counter, ctx} = counter(ctx, ctr)
    {:ok, Ash.update(counter, %{by: by}, action: :inc), ctx}
  end

  def step(ctx, %Step{action_taken: "Reset", nondet_picks: %{"value" => ctr}}) do
    {counter, ctx} = counter(ctx, ctr)
    {:ok, Ash.update(counter, %{}, action: :reset), ctx}
  end

  def step(ctx, %Step{action_taken: "Peek"}), do: {:skip, ctx}

  # The row named `ctr`, opened the first time the trace uses it.
  defp counter(ctx, ctr) do
    {id, ctx} = Names.fetch(ctx, :ctr, ctr)

    if MapSet.member?(ctx.ids, id) do
      {Ash.get!(Counter, id), ctx}
    else
      counter = Ash.create!(Counter, %{id: id}, action: :open)
      {counter, %{ctx | ids: MapSet.put(ctx.ids, id)}}
    end
  end

  @impl true
  def outcome(result), do: AshQuint.Ash.outcome(result, codes: %{Rejected => & &1.code})

  @impl true
  def project(ctx) do
    rows =
      Counter
      |> AshQuint.Ash.read_map(key: :id, fields: [:count, :writes])
      |> Map.take(MapSet.to_list(ctx.ids))
      |> Map.new(fn {id, row} -> {Names.reverse(ctx, :ctr, id), row} end)

    %{
      "counts" => Map.new(rows, fn {ctr, row} -> {ctr, row.count} end),
      "writes" => Map.new(rows, fn {ctr, row} -> {ctr, row.writes} end)
    }
  end

  @impl true
  def invariants do
    [
      counts_within_limit: fn projected, _ctx ->
        check(projected["counts"], &(&1 in 0..@limit), "outside 0..#{@limit}")
      end,
      writes_non_negative: fn projected, _ctx ->
        check(projected["writes"], &(&1 >= 0), "negative")
      end
    ]
  end

  defp check(map, valid?, problem) do
    case Enum.reject(map, fn {_ctr, value} -> valid?.(value) end) do
      [] -> :ok
      bad -> {:error, "#{problem}: #{inspect(Map.new(bad))}"}
    end
  end
end
