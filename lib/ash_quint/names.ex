defmodule AshQuint.Names do
  @moduledoc """
  Maps the model's small values (`1`, `"c1"`) to real ones (UUIDs, say),
  per trace.

  The first `fetch/4` of a `(kind, model_value)` pair generates a value, and
  later fetches return the same one. `reverse/3` maps a real value back to
  its model value, for projections keyed by model names.

  The names live under the `:ash_quint_names` key of the adapter's `ctx`,
  which must therefore be a map. A fresh `ctx` from `init/2` gives fresh
  names, so each trace (and each sensitivity mutant) gets its own.

      {id, ctx} = AshQuint.Names.fetch(ctx, :rec, picks["rec"])
      AshQuint.Names.reverse(ctx, :rec, id)   # => picks["rec"]
  """

  @key :ash_quint_names

  @doc """
  Returns the value named `model_value` under `kind`, and the `ctx` that
  remembers it. The first call for a pair generates the value with `gen`
  (default `uuid4/0`).

  Raises `ArgumentError` when `ctx` isn't a map, or when `gen` returns a
  value that already names another model value of the same kind.
  """
  @spec fetch(map(), term(), term(), (-> term())) :: {term(), map()}
  def fetch(ctx, kind, model_value, gen \\ &uuid4/0)

  def fetch(ctx, kind, model_value, gen) when is_map(ctx) do
    names = Map.get(ctx, @key, %{forward: %{}, reverse: %{}})
    forward = Map.get(names.forward, kind, %{})

    case Map.fetch(forward, model_value) do
      {:ok, value} ->
        {value, ctx}

      :error ->
        value = gen.()
        reverse = Map.get(names.reverse, kind, %{})
        refuse_taken(reverse, kind, value, model_value)

        names = %{
          forward: Map.put(names.forward, kind, Map.put(forward, model_value, value)),
          reverse: Map.put(names.reverse, kind, Map.put(reverse, value, model_value))
        }

        {value, Map.put(ctx, @key, names)}
    end
  end

  def fetch(ctx, _kind, _model_value, _gen), do: refuse_ctx(ctx)

  @doc """
  Returns the model value that `value` names under `kind`.

  Raises `ArgumentError` for a value `fetch/4` didn't hand out under `kind`,
  so a projection never silently reports records the trace didn't name.
  """
  @spec reverse(map(), term(), term()) :: term()
  def reverse(ctx, kind, value) when is_map(ctx) do
    with {:ok, names} <- Map.fetch(ctx, @key),
         {:ok, reverse} <- Map.fetch(names.reverse, kind),
         {:ok, model_value} <- Map.fetch(reverse, value) do
      model_value
    else
      :error ->
        raise ArgumentError, "no model name for #{inspect(value)} under #{inspect(kind)}"
    end
  end

  def reverse(ctx, _kind, _value), do: refuse_ctx(ctx)

  @doc """
  Returns a random RFC 4122 version 4 UUID as a lowercase string.
  """
  @spec uuid4() :: String.t()
  def uuid4 do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    <<u0::32, u1::16, u2::16, u3::16, u4::48>> = <<a::48, 4::4, b::12, 2::2, c::62>>

    [<<u0::32>>, <<u1::16>>, <<u2::16>>, <<u3::16>>, <<u4::48>>]
    |> Enum.map_join("-", &Base.encode16(&1, case: :lower))
  end

  defp refuse_taken(reverse, kind, value, model_value) do
    case Map.fetch(reverse, value) do
      {:ok, other} ->
        raise ArgumentError,
              "the generator for #{inspect(kind)} returned #{inspect(value)} for " <>
                "#{inspect(model_value)}, already the name of #{inspect(other)}"

      :error ->
        :ok
    end
  end

  defp refuse_ctx(ctx) do
    raise ArgumentError, "AshQuint.Names needs a map ctx, got: #{inspect(ctx)}"
  end
end
