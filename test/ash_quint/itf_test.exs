defmodule AshQuint.ITFTest do
  use ExUnit.Case, async: true

  alias AshQuint.ITF
  alias AshQuint.Trace

  @fixtures "test/fixtures/itf"

  defp fixture(name), do: Path.join(@fixtures, name)

  test "decodes every value form from a real quint run trace" do
    trace = ITF.read!(fixture("run.itf.json"))

    assert %Trace{path: "test/fixtures/itf/run.itf.json", name: nil, source: nil, seed: nil} =
             trace

    assert trace.vars == ["lastAction", "lastResult", "lst", "m", "n", "rec", "s", "st", "tup"]

    [s0, s1, s2, s3 | _] = trace.states

    assert s0["n"] == 1_099_511_627_776
    assert s2["n"] == 1_099_511_627_777
    assert s0["s"] == "hello"
    assert s0["m"] == %{"x" => 1, "y" => 2}
    assert s0["st"] == MapSet.new([1, 2, 3])
    assert s0["tup"] == {1, "one"}
    assert s0["lst"] == [1, 2]
    assert s0["rec"] == %{"a" => 1, "b" => "b"}

    assert s0["lastAction"] == {:variant, "Init", {}}
    assert s0["lastResult"] == {:variant, "Accepted", {}}
    assert s1["lastAction"] == {:variant, "Reset", {}}
    assert s1["lastResult"] == {:variant, "Rejected", "not_allowed"}
    assert s2["lastAction"] == {:variant, "Inc", %{"by" => 1}}
    assert s3["lastAction"] == {:variant, "SetTo", 5}
  end

  test "decodes #bigint beyond 2^53" do
    # Quint 0.33.1 writes such values as bignumber.js objects (next test).
    assert ITF.decode_value(%{"#bigint" => "9007199254740993"}, "$") == 9_007_199_254_740_993
    assert ITF.decode_value(%{"#bigint" => "-9007199254740993"}, "$") == -9_007_199_254_740_993
  end

  test "decodes the bignumber.js objects Quint writes for |n| >= 10^15" do
    [state] = ITF.read!(fixture("bignum.itf.json")).states

    assert state["xs"] == [
             999_999_999_999_999,
             1_000_000_000_000_000,
             -1_000_000_000_000_000,
             9_007_199_254_740_993,
             -9_007_199_254_740_993,
             1_000_000_000_000_000_000,
             1_230_000_000_000_000_000,
             1_000_000_000_000_001,
             1_000_000_000_000_000_001,
             9_223_372_036_854_775_807,
             -9_223_372_036_854_775_808
           ]
  end

  test "keeps a record with s, e and c fields that isn't a consistent bignumber" do
    big = fn s, e, c ->
      %{
        "s" => %{"#bigint" => s},
        "e" => %{"#bigint" => e},
        "c" => Enum.map(c, &%{"#bigint" => &1})
      }
    end

    # the first chunk must hold (e mod 14) + 1 digits
    assert ITF.decode_value(big.("1", "15", ["1"]), "$") == %{"s" => 1, "e" => 15, "c" => [1]}
    # the sign must be 1 or -1
    assert ITF.decode_value(big.("2", "15", ["10"]), "$") == %{"s" => 2, "e" => 15, "c" => [10]}
    # later chunks must be below 10^14
    assert ITF.decode_value(big.("1", "15", ["10", "100000000000000"]), "$") ==
             %{"s" => 1, "e" => 15, "c" => [10, 100_000_000_000_000]}

    # Quint writes integers below 10^15 as #bigint, so e must be at least 15
    assert ITF.decode_value(big.("1", "2", ["123"]), "$") == %{"s" => 1, "e" => 2, "c" => [123]}
    assert ITF.decode_value(big.("1", "14", ["1"]), "$") == %{"s" => 1, "e" => 14, "c" => [1]}

    # a record with other fields besides s, e and c
    extra = Map.put(big.("1", "15", ["10"]), "d", %{"#bigint" => "0"})

    assert ITF.decode_value(extra, "$") == %{"s" => 1, "e" => 15, "c" => [10], "d" => 0}
  end

  test "refuses a #bigint that isn't a decimal integer string" do
    for digits <- ["12x", "", "1.5", 12] do
      error =
        assert_raise ITF.Error, fn ->
          ITF.decode_value(%{"m" => %{"#bigint" => digits}}, "$.states[0]")
        end

      assert Exception.message(error) ==
               "$.states[0].m: #bigint must be a string of decimal digits, got #{inspect(digits)}"
    end
  end

  test "decodes plain JSON scalars and nested forms" do
    assert ITF.decode_value(true, "$") == true
    assert ITF.decode_value(3, "$") == 3

    assert ITF.decode_value(
             %{"#map" => [[%{"#tup" => [1, "a"]}, %{"#set" => [%{"#bigint" => "2"}]}]]},
             "$"
           ) == %{{1, "a"} => MapSet.new([2])}
  end

  test "drops #meta from every state" do
    trace = ITF.read!(fixture("run.itf.json"))
    raw = fixture("run.itf.json") |> File.read!() |> Jason.decode!()

    assert length(trace.states) == length(raw["states"])
    assert length(trace.states) == 5
    refute Enum.any?(trace.states, &Map.has_key?(&1, "#meta"))
  end

  test "strips module qualifiers from a quint test trace" do
    trace = ITF.read!(fixture("qualified.itf.json"))

    assert trace.vars == ["count", "lastAction", "lastResult"]

    for state <- trace.states do
      assert state |> Map.keys() |> Enum.sort() == ["count", "lastAction", "lastResult"]
    end

    assert Enum.map(trace.states, & &1["count"]) == [0, 1, 2]
  end

  test "strip/1 keeps the part after the last ::" do
    assert ITF.strip("tests::model::live") == "live"
    assert ITF.strip("live") == "live"
  end

  test "deduplicates repeated vars" do
    trace = ITF.read!(fixture("duplicate_vars.itf.json"))
    assert trace.vars == ["x", "y"]
  end

  test "refuses two qualified names that strip to the same name" do
    error = assert_raise ITF.Error, fn -> ITF.read!(fixture("duplicate_stripped.itf.json")) end

    assert Exception.message(error) ==
             "test/fixtures/itf/duplicate_stripped.itf.json at $.vars: a::x and b::x both strip to x"
  end

  test "refuses two state keys that strip to the same name" do
    json = %{"vars" => ["x"], "states" => [%{"a::x" => 1, "b::x" => 2}]}
    error = assert_raise ITF.Error, fn -> ITF.decode!(json, "mem.itf.json") end

    assert Exception.message(error) ==
             "mem.itf.json at $.states[0]: a::x and b::x both strip to x"
  end

  test "refuses unknown ITF forms with the JSON path" do
    error = assert_raise ITF.Error, fn -> ITF.read!(fixture("unserializable.itf.json")) end

    assert Exception.message(error) ==
             "test/fixtures/itf/unserializable.itf.json at $.states[1].v: unknown ITF form #unserializable"
  end

  test "reports the JSON path of nested unknown forms" do
    error =
      assert_raise ITF.Error, fn ->
        ITF.decode_value(%{"r" => [1, %{"tag" => "T", "value" => %{"#x" => 1}}]}, "$.states[0].v")
      end

    assert Exception.message(error) == "$.states[0].v.r[1].value: unknown ITF form #x"
  end

  test "refuses a #map entry that isn't a key-value pair" do
    error =
      assert_raise ITF.Error, fn ->
        ITF.decode_value(%{"#map" => [[1, 2], [3]]}, "$.states[0].m")
      end

    assert Exception.message(error) ==
             "$.states[0].m.#map[1]: a #map entry must be a [key, value] pair, got [3]"
  end

  test "refuses malformed JSON" do
    error = assert_raise ITF.Error, fn -> ITF.read!(fixture("malformed.json")) end
    {:error, decode_error} = fixture("malformed.json") |> File.read!() |> Jason.decode()

    assert Exception.message(error) ==
             "test/fixtures/itf/malformed.json at $: " <> Exception.message(decode_error)
  end

  test "refuses JSON that isn't an ITF trace" do
    error = assert_raise ITF.Error, fn -> ITF.decode!(%{"states" => []}, "x.json") end

    assert Exception.message(error) ==
             "x.json at $: not an ITF trace (needs vars and states lists)"
  end

  # The atom count is VM-wide, so other async tests would make a before/after
  # comparison flaky. Instead, check that the trace's unique strings never
  # became atoms.
  test "creates no atoms" do
    tag = "tag_#{System.unique_integer([:positive])}"
    key = "key_#{System.unique_integer([:positive])}"

    %{
      "vars" => [key],
      "states" => [%{"#meta" => %{}, key => %{"tag" => tag, "value" => %{key => 1}}}]
    }
    |> Jason.encode!()
    |> Jason.decode!()
    |> ITF.decode!("mem")

    for string <- [tag, key] do
      assert_raise ArgumentError, fn -> String.to_existing_atom(string) end
    end
  end
end
