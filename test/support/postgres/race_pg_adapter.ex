defmodule AshQuint.Test.RacePgAdapter do
  @moduledoc false
  # AshQuint.Test.RaceAdapter over Postgres: replays the race example
  # against AshQuint.Test.PgRaceCounter, unboxed (each op task has a
  # connection of its own, and every write commits).
  #
  #   * init/2 opens one committed row for the trace; project/1 reads only
  #     that row, since the rows of earlier replays and mutants stay.
  #   * IncStart({op, by}) starts the update in an op task: it records its
  #     backend (AshQuint.Ash.pg_backend_pid/1), fetches the row and runs
  #     the action, which stops at its AshQuint.Ash.Gate (:after_read in
  #     :inc, inside the action's transaction; :requested in :inc_atomic).
  #   * blocked?/2 asks Postgres whether the op waits on a lock.
  #   * finish/2 deletes the row, once every op task has stopped.
  #
  # `adapter_opts: [action: :inc | :inc_atomic]`, default :inc_atomic.
  use AshQuint.Adapter

  alias AshQuint.Step
  alias AshQuint.Test.{PgRaceCounter, Rejected}
  alias AshQuint.TestRepo

  @limit 3

  @impl true
  def init(_trace, opts) do
    row = Ash.create!(PgRaceCounter, %{id: Ash.UUID.generate()}, action: :open)
    {:ok, %{id: row.id, action: Keyword.get(opts, :action, :inc_atomic)}}
  end

  @impl true
  def step(ctx, %Step{action_taken: "IncStart", nondet_picks: %{"op" => op, "by" => by}}) do
    call = fn ->
      AshQuint.Ash.pg_backend_pid(TestRepo)

      PgRaceCounter
      |> Ash.get!(ctx.id)
      |> Ash.update(%{by: by}, action: ctx.action)
    end

    {:start, op, call, ctx}
  end

  def step(ctx, %Step{action_taken: "IncDone", nondet_picks: %{"op" => op}}),
    do: {:complete, op, ctx}

  @impl true
  def blocked?(_ctx, op_info), do: AshQuint.Ash.pg_blocked?(TestRepo, op_info)

  @impl true
  def outcome(result), do: AshQuint.Ash.outcome(result, codes: %{Rejected => & &1.code})

  @impl true
  def project(ctx) do
    row = Ash.get!(PgRaceCounter, ctx.id)
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
    PgRaceCounter |> Ash.get!(ctx.id) |> Ash.destroy!()
    :ok
  end
end
