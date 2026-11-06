defmodule AshQuint.AdapterTest do
  use ExUnit.Case, async: true

  alias Ash.Error.Invalid
  alias AshQuint.{Adapter, Step}
  alias AshQuint.Test.{PostconditionToyAdapter, Rejected, ToyAdapter}

  defmodule Minimal do
    @moduledoc false
    use AshQuint.Adapter

    @impl true
    def init(_trace, _opts), do: {:ok, %{}}

    @impl true
    def step(ctx, _step), do: {:skip, ctx}

    @impl true
    def project(_ctx), do: %{"count" => 1}
  end

  defmodule Custom do
    @moduledoc false
    use AshQuint.Adapter

    @impl true
    def init(_trace, _opts), do: {:ok, %{}}

    @impl true
    def step(ctx, _step), do: {:skip, ctx}

    @impl true
    def project(_ctx), do: %{}

    @impl true
    def expected(ctx, step), do: %{"from" => {ctx, step.index}}

    @impl true
    def outcome(:yes), do: :accepted
    def outcome(other), do: {:rejected, inspect(other)}

    @impl true
    def invariants, do: [always: fn _projected, _ctx -> :ok end]
  end

  defp step(state),
    do: %Step{index: 2, action_taken: "Inc", nondet_picks: %{}, result: nil, state: state}

  test "use AshQuint.Adapter: outcome defaults to AshQuint.Ash.outcome/1" do
    assert Minimal.outcome({:ok, 1}) == :accepted

    assert {:failed, message} =
             Minimal.outcome({:error, %Invalid{errors: [%Rejected{code: "x"}]}})

    assert message =~ "rejected: x"
  end

  test "default_outcome without Ash" do
    assert Adapter.default_outcome({:ok, 1}) == :accepted
    assert Adapter.default_outcome(:ok) == :accepted
    assert Adapter.default_outcome({:error, :x}) == {:failed, "{:error, :x}"}
  end

  test "outcome is overridable" do
    assert Custom.outcome(:yes) == :accepted
    assert Custom.outcome(:no) == {:rejected, ":no"}
  end

  test "expected defaults to the model state on the projected keys" do
    step = step(%{"count" => 2, "other" => 5})
    assert Adapter.expected(Minimal, %{}, step, %{"count" => 1}) == %{"count" => 2}
  end

  test "expected uses the adapter's expected/2 when defined" do
    assert Adapter.expected(Custom, :ctx, step(%{}), %{"count" => 1}) == %{"from" => {:ctx, 2}}
  end

  test "invariants default to none" do
    assert Adapter.invariants(Minimal) == []
    assert [always: fun] = Adapter.invariants(Custom)
    assert fun.(%{}, %{}) == :ok
  end

  test "project/2 calls project/1" do
    {:ok, ctx} = ToyAdapter.init(nil, [])
    assert Adapter.project(ToyAdapter, ctx) == %{"count" => 0}
  end

  test "project/2 without project/1 is empty" do
    {:ok, ctx} = PostconditionToyAdapter.init(nil, [])
    assert Adapter.project(PostconditionToyAdapter, ctx) == %{}
  end

  test "postconditions/1 defaults to none" do
    assert Adapter.postconditions(ToyAdapter) == []
    assert [count_matches: fun] = Adapter.postconditions(PostconditionToyAdapter)
    {:ok, ctx} = PostconditionToyAdapter.init(nil, [])
    assert fun.(ctx, step(%{"count" => 0})) == :ok
    assert fun.(ctx, step(%{"count" => 1})) == {:error, "count 0, model 1"}
  end
end
