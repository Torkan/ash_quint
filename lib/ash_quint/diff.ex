defmodule AshQuint.Diff do
  @moduledoc false

  # The differing entries of two maps or two MapSets, one line each, for
  # the replay's key mismatch messages.

  @doc """
  Lists the differences between `expected` and `actual` when both are maps
  (not structs) or both are `MapSet`s; `:whole` for any other pair.

  Map keys are sorted and walked depth first, with the path of keys joined
  by ` > `. At most `limit` lines, then a count of the rest.
  """
  @spec lines(term(), term(), pos_integer()) :: {:ok, [String.t()]} | :whole
  def lines(expected, actual, limit \\ 20) do
    case kind(expected, actual) do
      :map -> {:ok, expected |> map_lines(actual, []) |> cap(limit)}
      :set -> {:ok, expected |> set_line(actual, "elements") |> List.wrap() |> cap(limit)}
      :other -> :whole
    end
  end

  defp kind(%MapSet{}, %MapSet{}), do: :set
  defp kind(e, a) when is_struct(e) or is_struct(a), do: :other
  defp kind(e, a) when is_map(e) and is_map(a), do: :map
  defp kind(_e, _a), do: :other

  defp map_lines(expected, actual, path) do
    (Map.keys(expected) ++ Map.keys(actual))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(&key_lines(&1, expected, actual, path ++ [&1]))
  end

  defp key_lines(key, expected, actual, path) do
    case {Map.fetch(expected, key), Map.fetch(actual, key)} do
      {{:ok, e}, :error} -> ["#{label(path)}: missing (expected #{show(e)})"]
      {:error, {:ok, a}} -> ["#{label(path)}: unexpected (actual #{show(a)})"]
      {{:ok, same}, {:ok, same}} -> []
      {{:ok, e}, {:ok, a}} -> value_lines(e, a, path)
    end
  end

  defp value_lines(e, a, path) do
    case kind(e, a) do
      :map -> map_lines(e, a, path)
      :set -> List.wrap(set_line(e, a, label(path)))
      :other -> ["#{label(path)}: expected #{show(e)}, actual #{show(a)}"]
    end
  end

  defp set_line(expected, actual, label) do
    sides =
      for {name, set} <- [
            missing: MapSet.difference(expected, actual),
            unexpected: MapSet.difference(actual, expected)
          ],
          MapSet.size(set) > 0,
          do: "#{name} #{set |> Enum.sort() |> show()}"

    if sides != [], do: "#{label}: " <> Enum.join(sides, ", ")
  end

  defp label(path), do: Enum.map_join(path, " > ", &show/1)

  defp show(value), do: inspect(value, limit: :infinity, printable_limit: :infinity)

  defp cap(lines, limit) do
    case Enum.split(lines, limit) do
      {kept, []} -> kept
      {kept, [_]} -> kept ++ ["… and 1 more difference"]
      {kept, rest} -> kept ++ ["… and #{length(rest)} more differences"]
    end
  end
end
