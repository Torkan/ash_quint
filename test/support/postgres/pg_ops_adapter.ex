defmodule AshQuint.Test.PgOpsAdapter do
  @moduledoc false
  # Replays the toy counter's IncStart/IncDone steps with calls given per
  # op: `adapter_opts: [calls: %{"o1" => fun}]`. Nothing is projected; every
  # result is accepted. With `blocked: true`, blocked?/2 asks Postgres
  # (AshQuint.Ash.pg_blocked?/2).
  use AshQuint.Adapter

  alias AshQuint.Step

  @impl true
  def init(_trace, opts) do
    {:ok, %{calls: Keyword.fetch!(opts, :calls), blocked: Keyword.get(opts, :blocked, false)}}
  end

  @impl true
  def step(ctx, %Step{action_taken: "IncStart", nondet_picks: %{"op" => op}}),
    do: {:start, op, Map.fetch!(ctx.calls, op), ctx}

  def step(ctx, %Step{action_taken: "IncDone", nondet_picks: %{"op" => op}}),
    do: {:complete, op, ctx}

  @impl true
  def project(_ctx), do: %{}

  @impl true
  def outcome(_result), do: :accepted

  @impl true
  def blocked?(%{blocked: true}, op_info),
    do: AshQuint.Ash.pg_blocked?(AshQuint.TestRepo, op_info)

  def blocked?(_ctx, _op_info), do: false
end
