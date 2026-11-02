defmodule AshQuint.NamesTest do
  use ExUnit.Case, async: true

  alias AshQuint.Names

  @uuid_v4 ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  test "fetch returns a fresh UUID the first time and the same one after" do
    {first, ctx} = Names.fetch(%{}, :rec, 1)
    {again, ctx} = Names.fetch(ctx, :rec, 1)
    {other, _ctx} = Names.fetch(ctx, :rec, 2)

    assert first == again
    assert first =~ @uuid_v4
    assert other =~ @uuid_v4
    assert other != first
  end

  test "kinds are separate" do
    {rec, ctx} = Names.fetch(%{}, :rec, 1)
    {plan, _ctx} = Names.fetch(ctx, :plan, 1)

    assert rec != plan
  end

  test "fresh ctx gives fresh names" do
    {a, _} = Names.fetch(%{}, :rec, 1)
    {b, _} = Names.fetch(%{}, :rec, 1)

    assert a != b
  end

  test "custom generator" do
    assert {"r-1", ctx} = Names.fetch(%{}, :rec, 1, fn -> "r-1" end)
    assert {"r-1", _ctx} = Names.fetch(ctx, :rec, 1, fn -> "unused" end)
  end

  test "keeps the adapter's own ctx keys" do
    {_value, ctx} = Names.fetch(%{count: 3}, :rec, 1)
    assert ctx.count == 3
  end

  test "reverse maps back" do
    {value, ctx} = Names.fetch(%{}, :rec, 1)
    {_plan, ctx} = Names.fetch(ctx, :plan, 2)

    assert Names.reverse(ctx, :rec, value) == 1

    assert_raise ArgumentError, ~s(no model name for "x" under :rec), fn ->
      Names.reverse(ctx, :rec, "x")
    end
  end

  test "reverse of a value of another kind is refused" do
    {plan, ctx} = Names.fetch(%{}, :plan, 1)

    assert_raise ArgumentError, "no model name for #{inspect(plan)} under :rec", fn ->
      Names.reverse(ctx, :rec, plan)
    end
  end

  test "reverse on a ctx without names is refused" do
    assert_raise ArgumentError, ~s(no model name for "x" under :rec), fn ->
      Names.reverse(%{}, :rec, "x")
    end
  end

  test "a generator returning a taken value is refused" do
    {_value, ctx} = Names.fetch(%{}, :rec, 1, fn -> "r" end)

    assert_raise ArgumentError,
                 ~s(the generator for :rec returned "r" for 2, already the name of 1),
                 fn -> Names.fetch(ctx, :rec, 2, fn -> "r" end) end
  end

  test "non-map ctx is refused" do
    assert_raise ArgumentError, "AshQuint.Names needs a map ctx, got: :nope", fn ->
      Names.fetch(:nope, :rec, 1)
    end

    assert_raise ArgumentError, "AshQuint.Names needs a map ctx, got: :nope", fn ->
      Names.reverse(:nope, :rec, "x")
    end
  end

  test "uuid4/0 returns RFC 4122 version 4 UUIDs" do
    assert Names.uuid4() =~ @uuid_v4
    assert Names.uuid4() != Names.uuid4()
  end
end
