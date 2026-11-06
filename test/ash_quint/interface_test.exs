defmodule AshQuint.InterfaceTest do
  use ExUnit.Case, async: true

  alias AshQuint.Interface

  @opts [action_path: ["lastAction"], result_path: ["lastResult"], quint: "0.33.1"]

  @counter %Interface{
    actions: [
      %{name: "Init", picks: :unit, type: nil},
      %{
        name: "Inc",
        picks: :record,
        fields: [%{name: "ctr", type: "str"}, %{name: "by", type: "int"}]
      },
      %{name: "Reset", picks: :value, type: "str"},
      %{name: "Peek", picks: :value, type: "str"}
    ],
    results: ["Accepted", "Rejected"],
    vars: [%{name: "counts", type: "str -> int"}, %{name: "writes", type: "str -> int"}]
  }

  @race %Interface{
    actions: [
      %{name: "Init", picks: :unit, type: nil},
      %{
        name: "IncStart",
        picks: :record,
        fields: [%{name: "op", type: "str"}, %{name: "by", type: "int"}]
      },
      %{name: "IncDone", picks: :record, fields: [%{name: "op", type: "str"}]}
    ],
    results: ["Accepted", "Rejected", "Pending"],
    vars: [
      %{name: "count", type: "int"},
      %{name: "writes", type: "int"},
      %{name: "inflight", type: "str -> int"},
      %{name: "finished", type: "Set[str]"}
    ]
  }

  defp fixture(name), do: "test/fixtures/quint_ir/#{name}.json" |> File.read!() |> Jason.decode!()

  # A hand-built IR: one module declaring `vars` ({name, type}), each with
  # its entry in the `types` table.
  defp ir(vars) do
    decls =
      vars
      |> Enum.with_index(1)
      |> Enum.map(fn {{name, _type}, id} -> %{"kind" => "var", "name" => name, "id" => id} end)

    types =
      vars
      |> Enum.with_index(1)
      |> Map.new(fn {{_name, type}, id} -> {Integer.to_string(id), %{"type" => type}} end)

    %{"modules" => [%{"name" => "m", "declarations" => decls}], "types" => types}
  end

  defp row(fields),
    do: %{
      "kind" => "row",
      "fields" => Enum.map(fields, fn {n, t} -> %{"fieldName" => n, "fieldType" => t} end),
      "other" => %{"kind" => "empty"}
    }

  defp sum(fields), do: %{"kind" => "sum", "fields" => row(fields)}
  defp rec(fields), do: %{"kind" => "rec", "fields" => row(fields)}
  defp tup(elems), do: %{"kind" => "tup", "fields" => row(Enum.with_index(elems, &{"#{&2}", &1}))}
  defp unit, do: tup([])
  defp int, do: %{"kind" => "int"}
  defp str, do: %{"kind" => "str"}
  defp fun(a, b), do: %{"kind" => "fun", "arg" => a, "res" => b}

  test "counter's interface" do
    assert Interface.from_ir(fixture("counter"), @opts) == {:ok, @counter}
  end

  test "race's interface" do
    assert Interface.from_ir(fixture("race"), @opts) == {:ok, @race}
  end

  test "the tests module finds the imported module's vars" do
    assert Interface.from_ir(fixture("counter_tests"), @opts) == {:ok, @counter}
  end

  test "a nested action path follows record fields" do
    ir = ir([{"state", rec([{"lastAction", sum([{"A", unit()}, {"B", int()}])}])}, {"n", int()}])

    assert Interface.from_ir(ir, Keyword.put(@opts, :action_path, ["state", "lastAction"])) ==
             {:ok,
              %Interface{
                actions: [
                  %{name: "A", picks: :unit, type: nil},
                  %{name: "B", picks: :value, type: "int"}
                ],
                results: nil,
                vars: [%{name: "n", type: "int"}]
              }}
  end

  test "qualified var names are stripped and deduplicated" do
    ir =
      ir([
        {"tests::m::lastAction", sum([{"A", unit()}])},
        {"tests::m::n", int()},
        {"m::n", int()}
      ])

    assert {:ok, %Interface{vars: [%{name: "n", type: "int"}]}} = Interface.from_ir(ir, @opts)
  end

  test "an action var that isn't a sum is an error" do
    ir = ir([{"lastAction", fun(str(), int())}])

    assert Interface.from_ir(ir, @opts) ==
             {:error, "the action at lastAction must be a sum type, got str -> int"}
  end

  test "a path through a non-record is an error" do
    ir = ir([{"state", int()}])

    assert Interface.from_ir(ir, Keyword.put(@opts, :action_path, ["state", "lastAction"])) ==
             {:error, "the action at state.lastAction must be a sum type, got int"}
  end

  test "a missing action var is an error" do
    assert Interface.from_ir(ir([{"n", int()}]), @opts) ==
             {:error, "no variable lastAction in the model"}
  end

  test "a result path to a non-sum is an error" do
    ir = ir([{"lastAction", sum([{"A", unit()}])}, {"lastResult", str()}])

    assert Interface.from_ir(ir, @opts) ==
             {:error, "the result at lastResult must be a sum type, got str"}
  end

  test "a model without a result var has nil results" do
    ir = ir([{"lastAction", sum([{"A", unit()}])}, {"n", int()}])

    assert {:ok, %Interface{results: nil, vars: [%{name: "n", type: "int"}]}} =
             Interface.from_ir(ir, @opts)
  end

  test "a Map action value is shape map" do
    ir = ir([{"lastAction", sum([{"Set", fun(str(), int())}])}])

    assert {:ok, %Interface{actions: [%{name: "Set", picks: :map, type: "str -> int"}]}} =
             Interface.from_ir(ir, @opts)
  end

  test "a malformed IR is an error naming Quint's version" do
    message = "could not read the model interface from Quint 0.33.1's JSON IR: "

    assert Interface.from_ir(%{}, @opts) == {:error, message <> "no modules list"}

    missing_type = put_in(ir([{"n", int()}]), ["types"], %{})

    assert Interface.from_ir(missing_type, @opts) ==
             {:error, message <> "no type for variable n"}

    no_fields = ir([{"lastAction", %{"kind" => "sum"}}])
    assert Interface.from_ir(no_fields, @opts) == {:error, message <> "a type without fields"}
  end

  describe "render_type/1" do
    test "renders each kind" do
      assert Interface.render_type(int()) == "int"
      assert Interface.render_type(str()) == "str"
      assert Interface.render_type(%{"kind" => "bool"}) == "bool"
      assert Interface.render_type(%{"kind" => "set", "elem" => str()}) == "Set[str]"
      assert Interface.render_type(%{"kind" => "list", "elem" => int()}) == "List[int]"
      assert Interface.render_type(fun(str(), int())) == "str -> int"
      assert Interface.render_type(tup([int(), str()])) == "(int, str)"
      assert Interface.render_type(unit()) == "()"
      assert Interface.render_type(rec([{"f", int()}, {"g", str()}])) == "{ f: int, g: str }"
      assert Interface.render_type(sum([{"A", unit()}, {"B", int()}])) == "A | B(int)"
      assert Interface.render_type(%{"kind" => "const", "name" => "Action"}) == "Action"
      assert Interface.render_type(%{"kind" => "var", "name" => "t"}) == "t"
    end

    test "an unknown type kind renders as ?" do
      assert Interface.render_type(%{"kind" => "oper"}) == "?"
    end
  end

  test "round-trips through JSON" do
    for interface <- [@counter, @race, %Interface{actions: [], results: nil, vars: []}] do
      json = Jason.encode!(Interface.to_json(interface))
      assert Interface.from_json!(Jason.decode!(json), "m") == interface
    end

    encoded = Jason.encode!(Interface.to_json(@counter))
    assert encoded =~ ~r/\A\{"actions":.*,"results":.*,"vars":/

    assert encoded =~
             ~s({"fields":[{"name":"ctr","type":"str"},{"name":"by","type":"int"}],) <>
               ~s("name":"Inc","picks":"record"})

    assert encoded =~ ~s({"name":"Init","picks":"unit"})
    assert encoded =~ ~s({"name":"Reset","picks":"value","type":"str"})
  end

  test "from_json! refuses an unknown picks" do
    json = %{
      "actions" => [%{"name" => "A", "picks" => "tuple"}],
      "results" => nil,
      "vars" => []
    }

    assert_raise ArgumentError,
                 "m: invalid manifest: interface.actions[0].picks must be one of " <>
                   "map, record, unit, value",
                 fn -> Interface.from_json!(json, "m") end
  end

  test "from_json! refuses malformed fields" do
    valid = Jason.decode!(Jason.encode!(Interface.to_json(@counter)))

    assert_raise ArgumentError,
                 "m: invalid manifest: interface.vars must be a list of name and type",
                 fn -> Interface.from_json!(%{valid | "vars" => [%{"name" => "n"}]}, "m") end

    assert_raise ArgumentError,
                 "m: invalid manifest: interface.results must be null or a list of strings",
                 fn -> Interface.from_json!(%{valid | "results" => [1]}, "m") end

    assert_raise ArgumentError,
                 "m: invalid manifest: interface.actions[1] is malformed",
                 fn ->
                   Interface.from_json!(
                     put_in(valid, ["actions", Access.at(1), "fields"], "x"),
                     "m"
                   )
                 end

    assert_raise ArgumentError,
                 "m: invalid manifest: interface.actions must be a list",
                 fn -> Interface.from_json!(%{valid | "actions" => %{}}, "m") end

    assert_raise ArgumentError, "m: invalid manifest: interface must be an object", fn ->
      Interface.from_json!([], "m")
    end
  end
end
