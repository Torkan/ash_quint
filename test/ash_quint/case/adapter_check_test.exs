defmodule AshQuint.Case.AdapterCheckTest do
  use ExUnit.Case, async: true

  alias AshQuint.Case.AdapterCheck
  alias AshQuint.{Config, Manifest, Scaffold}
  alias AshQuint.Test.AdapterCheck.{CatchAll, Missing, NoStep, PlainMap, Typo, UnknownPick}
  alias AshQuint.Test.{CounterAdapter, CounterAdapterOffByOne, RaceAdapter}

  defp model(name), do: Config.model!(Config.load!(), name)
  defp manifest(name), do: Manifest.read!(Path.join(model(name).out, "manifest.json"))
  defp interface(name), do: manifest(name).interface

  defp warnings(adapter, name \\ :counter),
    do: AdapterCheck.warnings(adapter, name, interface(name), "Init")

  describe "clauses/1" do
    test "clauses/1 reads literal actions and picks" do
      assert AdapterCheck.clauses(CounterAdapter) ==
               {:ok,
                [
                  %{action: "Inc", picks: ["by", "ctr"]},
                  %{action: "Reset", picks: ["value"]},
                  %{action: "Peek", picks: []}
                ]}
    end

    test "clauses/1 treats a variable action as a catch-all" do
      assert {:ok, clauses} = AdapterCheck.clauses(CounterAdapterOffByOne)
      assert clauses == [%{action: "Inc", picks: ["by"]}, %{action: :any, picks: :any}]
    end

    test "clauses/1 reads plain map patterns" do
      assert AdapterCheck.clauses(PlainMap) == {:ok, [%{action: "Inc", picks: ["by"]}]}
    end

    test "clauses/1 is unavailable without a step/2" do
      assert AdapterCheck.clauses(NoStep) == :unavailable

      module = Module.concat(__MODULE__, "InMemory#{System.unique_integer([:positive])}")

      Code.compile_string("""
      defmodule #{inspect(module)} do
        def step(ctx, %AshQuint.Step{action_taken: "Inc"}), do: ctx
      end
      """)

      assert AdapterCheck.clauses(module) == :unavailable
      assert AdapterCheck.clauses(Module.concat(__MODULE__, "Undefined")) == :unavailable
    end
  end

  describe "warnings/4" do
    test "an unknown action warns" do
      assert warnings(Typo) == [
               ~s(AshQuint.Test.AdapterCheck.Typo has a step/2 clause for "Incr", ) <>
                 "which isn't an action of :counter (actions: Inc, Reset, Peek)"
             ]
    end

    test "a missing action warns" do
      assert warnings(Missing) == [
               ~s(AshQuint.Test.AdapterCheck.Missing has no step/2 clause for "Reset" of :counter)
             ]
    end

    test "a catch-all clause silences missing actions" do
      assert warnings(CatchAll) == []
    end

    test "an unknown pick warns" do
      assert warnings(UnknownPick) == [
               ~s(AshQuint.Test.AdapterCheck.UnknownPick step/2 clause for "Inc" matches ) <>
                 ~s(pick "amount", which Inc doesn't have \(picks: ctr, by\))
             ]
    end

    test "a pick of a unit action warns with no picks" do
      interface = %AshQuint.Interface{
        actions: [
          %{name: "Init", picks: :unit, type: nil},
          %{name: "Inc", picks: :unit, type: nil},
          %{name: "Reset", picks: :value, type: "str"},
          %{name: "Peek", picks: :map, type: "str -> int"}
        ]
      }

      assert AdapterCheck.warnings(Typo, :toy, interface, "Init") == [
               ~s(AshQuint.Test.AdapterCheck.Typo step/2 clause for "Inc" matches ) <>
                 ~s(pick "by", which Inc doesn't have \(picks: none\)),
               ~s(AshQuint.Test.AdapterCheck.Typo step/2 clause for "Inc" matches ) <>
                 ~s(pick "ctr", which Inc doesn't have \(picks: none\)),
               ~s(AshQuint.Test.AdapterCheck.Typo has a step/2 clause for "Incr", ) <>
                 "which isn't an action of :toy (actions: Inc, Reset, Peek)"
             ]
    end

    test "the init action is never required, and a clause for it doesn't warn" do
      interface = %AshQuint.Interface{
        actions: [
          %{name: "Inc", picks: :record, fields: [%{name: "by", type: "int"}]},
          %{name: "Go", picks: :unit, type: nil}
        ]
      }

      assert AdapterCheck.warnings(PlainMap, :toy, interface, "Go") == []

      assert AdapterCheck.warnings(PlainMap, :toy, interface, "Inc") == [
               ~s(AshQuint.Test.AdapterCheck.PlainMap has no step/2 clause for "Go" of :toy)
             ]
    end

    test "no warnings without debug info" do
      assert AdapterCheck.warnings(NoStep, :counter, interface(:counter), "Init") == []
    end

    test "the reference adapters have no warnings" do
      assert warnings(CounterAdapter) == []
      assert warnings(CounterAdapterOffByOne) == []
      assert warnings(RaceAdapter, :race) == []
    end

    @tag :tmp_dir
    test "the scaffolded adapters have no warnings", %{tmp_dir: tmp_dir} do
      for name <- [:counter, :race] do
        module = Module.concat(__MODULE__, "Scaffolded#{System.unique_integer([:positive])}")
        source = Scaffold.adapter_source(module, manifest(name), model(name))

        assert warnings(load_beam(source, module, tmp_dir), name) == []
      end
    end
  end

  # Compiles `source` and reloads `module` from a beam file in `dir`, so
  # :code.which/1 finds its debug info.
  defp load_beam(source, module, dir) do
    {^module, binary} = List.keyfind(Code.compile_string(source), module, 0)
    base = Path.join(dir, Atom.to_string(module))
    File.write!(base <> ".beam", binary)
    :code.purge(module)
    true = :code.delete(module)
    {:module, ^module} = :code.load_abs(String.to_charlist(base))
    module
  end
end
