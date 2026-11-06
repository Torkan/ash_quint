defmodule AshQuint.DiffTest do
  use ExUnit.Case, async: true

  alias AshQuint.Diff

  test "changed, missing and unexpected entries, keys sorted" do
    assert Diff.lines(%{"c1" => 3, "c2" => 0}, %{"c1" => 4, "c3" => 1}) ==
             {:ok,
              [
                ~s("c1": expected 3, actual 4),
                ~s|"c2": missing (expected 0)|,
                ~s|"c3": unexpected (actual 1)|
              ]}
  end

  test "nested maps recurse with a key path" do
    assert Diff.lines(%{"c4" => %{"limit" => 3}}, %{"c4" => %{"limit" => 5}}) ==
             {:ok, [~s("c4" > "limit": expected 3, actual 5)]}
  end

  test "a map against a non-map is one line" do
    assert Diff.lines(%{"a" => %{"x" => 1}}, %{"a" => 2}) ==
             {:ok, [~s("a": expected %{"x" => 1}, actual 2)]}
  end

  test "MapSets give one elements line" do
    expected = MapSet.new(["o1", "o2"])
    actual = MapSet.new(["o2", "o3"])

    assert Diff.lines(expected, actual) ==
             {:ok, [~s(elements: missing ["o1"], unexpected ["o3"])]}

    assert Diff.lines(%{"done" => expected}, %{"done" => actual}) ==
             {:ok, [~s("done": missing ["o1"], unexpected ["o3"])]}
  end

  test "a MapSet line leaves out an empty side" do
    assert Diff.lines(MapSet.new(["o1", "o2"]), MapSet.new(["o2"])) ==
             {:ok, [~s(elements: missing ["o1"])]}

    assert Diff.lines(MapSet.new(["o2"]), MapSet.new(["o2", "o3"])) ==
             {:ok, [~s(elements: unexpected ["o3"])]}
  end

  test "equal maps give no lines" do
    assert Diff.lines(%{"a" => 1, "b" => %{"c" => 2}}, %{"a" => 1, "b" => %{"c" => 2}}) ==
             {:ok, []}
  end

  test "structs and other values are whole" do
    assert Diff.lines(~D[2024-01-01], ~D[2024-01-02]) == :whole
    assert Diff.lines([1, 2], [1, 3]) == :whole
    assert Diff.lines(%{"a" => 1}, [1]) == :whole
    assert Diff.lines(%{"a" => 1}, MapSet.new([1])) == :whole
  end

  test "structs inside maps are compared whole" do
    assert Diff.lines(%{"d" => ~D[2024-01-01]}, %{"d" => ~D[2024-01-02]}) ==
             {:ok, [~s("d": expected ~D[2024-01-01], actual ~D[2024-01-02])]}
  end

  test "caps the lines" do
    keys = for i <- 1..27, do: "k" <> String.pad_leading(Integer.to_string(i), 2, "0")
    expected = Map.new(keys, &{&1, 0})
    actual = Map.new(keys, &{&1, 1})

    assert {:ok, lines} = Diff.lines(expected, actual)
    assert length(lines) == 21
    assert hd(lines) == ~s("k01": expected 0, actual 1)
    assert Enum.at(lines, 19) == ~s("k20": expected 0, actual 1)
    assert List.last(lines) == "… and 7 more differences"

    assert {:ok, lines} = Diff.lines(Map.take(expected, keys), actual, 26)
    assert List.last(lines) == "… and 1 more difference"
  end

  test "values are inspected whole on one line" do
    long = Enum.to_list(1..60)

    assert Diff.lines(%{"l" => long}, %{"l" => []}) ==
             {:ok, ["\"l\": expected #{inspect(long, limit: :infinity)}, actual []"]}
  end
end
