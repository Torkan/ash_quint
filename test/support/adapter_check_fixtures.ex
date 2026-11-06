# Fixture adapters for AshQuint.Case.AdapterCheck, against the counter
# example's interface (Init, Inc({ctr, by}), Reset(str), Peek(str)). They
# are compiled to beams with test/support, so they carry debug info; only
# their step/2 clauses matter.

defmodule AshQuint.Test.AdapterCheck.Typo do
  @moduledoc false
  alias AshQuint.Step

  def step(ctx, %Step{action_taken: "Inc", nondet_picks: %{"ctr" => _, "by" => _}}), do: ctx
  def step(ctx, %Step{action_taken: "Incr", nondet_picks: %{"ctr" => _}}), do: ctx
  def step(ctx, %Step{action_taken: "Reset", nondet_picks: %{"value" => _}}), do: ctx
  def step(ctx, %Step{action_taken: "Peek"}), do: ctx
end

defmodule AshQuint.Test.AdapterCheck.Missing do
  @moduledoc false
  alias AshQuint.Step

  def step(ctx, %Step{action_taken: "Inc", nondet_picks: %{"ctr" => _, "by" => _}}), do: ctx
  def step(ctx, %Step{action_taken: "Peek"}), do: ctx
end

defmodule AshQuint.Test.AdapterCheck.CatchAll do
  @moduledoc false
  alias AshQuint.Step

  def step(ctx, %Step{action_taken: "Inc", nondet_picks: %{"by" => _}}), do: ctx
  def step(ctx, _step), do: ctx
end

defmodule AshQuint.Test.AdapterCheck.UnknownPick do
  @moduledoc false
  alias AshQuint.Step

  def step(ctx, %Step{action_taken: "Inc", nondet_picks: %{"amount" => _}}), do: ctx
  def step(ctx, %Step{action_taken: "Reset", nondet_picks: %{"value" => _}}), do: ctx
  def step(ctx, %Step{action_taken: "Peek"}), do: ctx
end

defmodule AshQuint.Test.AdapterCheck.PlainMap do
  @moduledoc false

  def step(ctx, %{action_taken: "Inc", nondet_picks: %{"by" => _}}), do: ctx
end

defmodule AshQuint.Test.AdapterCheck.NoStep do
  @moduledoc false

  def init(_trace, _opts), do: {:ok, %{}}
end
