defmodule AshQuint.Test.RaceAdapter do
  @moduledoc """
  The concurrency example's adapter: replays the race example
  (`priv/examples/race`) against the ETS-backed `AshQuint.Test.RaceCounter`
  resource, with the increments in flight in op tasks.

    * `init/2` opens one row for the trace (the model has one counter); its
      table isn't private, so op tasks see it, and `project/1` reads only
      this row.
    * `IncStart({op, by})` returns `{:start, op, call, ctx}`. The call
      fetches the row and runs the update in the op task, so the read
      happens there too; the action stops at its gate (`:after_read` in
      `:inc`, `:requested` in `:inc_atomic`) until the step that completes
      it.
    * `IncDone({op})` returns `{:complete, op, ctx}`: the replay releases
      the op and checks its outcome against the step's result.
    * `adapter_opts: [action: :inc | :inc_atomic]` picks the update action;
      the default, `:inc_atomic`, is the correct one. `:inc` is a
      read-modify-write that loses an update when two incs overlap.
    * `outcome/1` maps `AshQuint.Test.Rejected` to the model's
      `Rejected(code)`; `invariants/0` mirrors the model's
      `countWithinLimit`; `finish/2` destroys the row, after every op task
      has stopped.
  """
  use AshQuint.Adapter

  alias AshQuint.Step
  alias AshQuint.Test.{RaceCounter, Rejected}

  @limit 3

  @impl true
  def init(_trace, opts) do
    row = Ash.create!(RaceCounter, %{id: Ash.UUID.generate()}, action: :open)
    {:ok, %{id: row.id, action: Keyword.get(opts, :action, :inc_atomic)}}
  end

  @impl true
  def step(ctx, %Step{action_taken: "IncStart", nondet_picks: %{"op" => op, "by" => by}}) do
    call = fn ->
      RaceCounter
      |> Ash.get!(ctx.id)
      |> Ash.update(%{by: by}, action: ctx.action)
    end

    {:start, op, call, ctx}
  end

  def step(ctx, %Step{action_taken: "IncDone", nondet_picks: %{"op" => op}}),
    do: {:complete, op, ctx}

  @impl true
  def outcome(result), do: AshQuint.Ash.outcome(result, codes: %{Rejected => & &1.code})

  @impl true
  def project(ctx) do
    row = Ash.get!(RaceCounter, ctx.id)
    %{"count" => row.count, "writes" => row.writes}
  end

  @impl true
  def invariants do
    [
      count_within_limit: fn %{"count" => count}, _ctx ->
        if count in 0..@limit, do: :ok, else: {:error, "count #{count} is outside 0..#{@limit}"}
      end
    ]
  end

  @impl true
  def finish(ctx, _result) do
    RaceCounter |> Ash.get!(ctx.id) |> Ash.destroy!()
    :ok
  end
end
