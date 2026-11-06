defmodule AshQuint.ScaffoldTest do
  use ExUnit.Case, async: true

  alias AshQuint.{Config, Interface, Manifest, Replay, Scaffold, Trace}

  @config Config.load!()

  defp model(name), do: Config.model!(@config, name)

  defp manifest(name),
    do: Manifest.read!(Path.join(model(name).out, "manifest.json"))

  defp adapter(name, module \\ MyApp.Trace),
    do: Scaffold.adapter_source(module, manifest(name), model(name))

  # Compiles `source` under a fresh module name; returns the module and the
  # compiler's diagnostics.
  defp compile(source, module) do
    unique = Module.concat(__MODULE__, "Scaffolded#{System.unique_integer([:positive])}")
    source = String.replace(source, inspect(module), inspect(unique))

    {_result, diagnostics} =
      Code.with_diagnostics(fn -> Code.compile_string(source) end)

    {unique, diagnostics}
  end

  # A one-action manifest over `interface`, with `outcomes` for its traces.
  defp synthetic(actions, outcomes \\ [], vars \\ []) do
    interface = %Interface{
      actions: [%{name: "Init", picks: :unit, type: nil} | actions],
      results: ["Accepted", "Rejected", "Pending"],
      vars: vars
    }

    traces =
      for {outcome, index} <- Enum.with_index(outcomes) do
        %{
          file: "random_#{index}.itf.json",
          source: :random,
          name: "#{index}",
          steps: 1,
          actions:
            Map.new(outcome, fn {action, labels} -> {action, Enum.sum(Map.values(labels))} end),
          outcomes: outcome,
          concurrent: false,
          max_in_flight: 0
        }
      end

    %Manifest{quint: "0.33.1", seed: 1, interface: interface, traces: traces}
  end

  defp synthetic_model, do: %{model(:race) | name: :synthetic}

  test "the counter adapter compiles without warnings" do
    {_module, diagnostics} = compile(adapter(:counter), MyApp.Trace)
    assert diagnostics == []
  end

  test "record picks are bound" do
    source = adapter(:counter)
    assert source =~ "# Inc({ ctr: str, by: int })\n"

    assert source =~
             ~s|def step(ctx, %Step{action_taken: "Inc", nondet_picks: %{"ctr" => ctr, "by" => by}}) do\n| <>
               ~S|    {:ok, todo!("Inc(ctr: #{inspect(ctr)}, by: #{inspect(by)})"), ctx}|
  end

  test "value picks bind value; no clause for Init" do
    source = adapter(:counter)
    assert source =~ "# Reset(str)\n"

    assert source =~
             ~s|def step(ctx, %Step{action_taken: "Reset", nondet_picks: %{"value" => value}}) do\n| <>
               ~S|    {:ok, todo!("Reset(#{inspect(value)})"), ctx}|

    refute source =~ ~s(action_taken: "Init")
  end

  test "a replay fails clearly at the first step" do
    {module, []} = compile(adapter(:counter), MyApp.Trace)
    out = model(:counter).out

    trace =
      Trace.load!(Path.join(out, "scenario_incTest.itf.json"),
        name: "incTest",
        source: :scenario,
        seed: manifest(:counter).seed
      )

    assert {:error, %{index: 0, message: message}} = Replay.run(module, trace, model: :counter)
    assert message =~ "#{inspect(module)}: project counts is not implemented yet"
  end

  test "race: start and complete forms" do
    source = adapter(:race)

    assert source =~
             """
               # IncStart({ op: str, by: int })
               # Use {:advance, op, ctx} if this action advances an op that started earlier.
               @impl true
               def step(ctx, %Step{action_taken: "IncStart", nondet_picks: %{"op" => op, "by" => by}}) do
                 {:start, op, fn -> todo!("IncStart(op: \#{inspect(op)}, by: \#{inspect(by)})") end, ctx}
               end
             """

    assert source =~
             """
               # IncDone({ op: str })
               # The op's call was made by its start action; the replay checks its outcome here.
               def step(ctx, %Step{action_taken: "IncDone", nondet_picks: %{"op" => op}}) do
                 {:complete, op, ctx}
               end
             """

    assert {_module, []} = compile(source, MyApp.Trace)
  end

  test "a completion binds its other picks unused" do
    manifest =
      synthetic(
        [
          %{
            name: "Done",
            picks: :record,
            fields: [%{name: "op", type: "str"}, %{name: "code", type: "str"}]
          }
        ],
        [%{"Done" => %{"accepted" => 1}}],
        [%{name: "count", type: "int"}]
      )

    source = Scaffold.adapter_source(MyApp.Trace, manifest, synthetic_model())
    assert source =~ ~s|nondet_picks: %{"op" => op, "code" => _code}}) do|
    assert {_module, []} = compile(source, MyApp.Trace)
  end

  test "an action no trace takes gets an :ok clause naming both forms" do
    manifest =
      synthetic([%{name: "Start", picks: :record, fields: [%{name: "op", type: "str"}]}])

    source = Scaffold.adapter_source(MyApp.Trace, manifest, synthetic_model())

    assert source =~
             """
               # Start({ op: str })
               # No trace takes this action: return {:start, op, call, ctx} if it starts a call
               # that stays in flight, {:complete, op, ctx} if it completes one.
               @impl true
               def step(ctx, %Step{action_taken: "Start", nondet_picks: %{"op" => op}}) do
                 {:ok, todo!("Start(op: \#{inspect(op)})"), ctx}
               end
             """

    assert {_module, []} = compile(source, MyApp.Trace)
  end

  test "an action without the op field is sequential" do
    manifest =
      synthetic(
        [%{name: "Inc", picks: :record, fields: [%{name: "by", type: "int"}]}],
        [%{"Inc" => %{"pending" => 1}}]
      )

    source = Scaffold.adapter_source(MyApp.Trace, manifest, synthetic_model())
    assert source =~ ~S|{:ok, todo!("Inc(by: #{inspect(by)})"), ctx}|
  end

  test "project lists every var with its type" do
    source = adapter(:race)

    assert source =~
             """
                   # str -> int
                   "inflight" => todo!("project inflight"),
             """

    assert source =~ "sensitivity: [allow_untested: [vars: [...]]]"
  end

  test "project without vars" do
    source = Scaffold.adapter_source(MyApp.Trace, synthetic([]), synthetic_model())
    assert source =~ "def project(_ctx), do: %{}"
    assert {_module, []} = compile(source, MyApp.Trace)
  end

  test "reserved words and map picks" do
    manifest =
      synthetic(
        [
          %{
            name: "Set",
            picks: :record,
            fields: [
              %{name: "do", type: "str"},
              %{name: "ctx", type: "str"},
              %{name: "fooBar", type: "int"},
              %{name: "foo_bar", type: "int"},
              %{name: "_x", type: "int"}
            ]
          },
          %{name: "Load", picks: :map, type: "str -> int"},
          %{name: "Tick", picks: :unit, type: nil}
        ],
        [],
        [%{name: "count", type: "int"}]
      )

    source = Scaffold.adapter_source(MyApp.Trace, manifest, synthetic_model())

    for binding <- [
          ~s("do" => do_,),
          ~s("ctx" => ctx_,),
          ~s("fooBar" => foo_bar,),
          ~s("foo_bar" => foo_bar_2,),
          ~s("_x" => x\n)
        ] do
      assert source =~ binding
    end

    assert source =~ "# Load(str -> int)\n"
    assert source =~ ~s|nondet_picks: picks}) do\n|
    assert source =~ ~S|{:ok, todo!("Load(#{inspect(picks)})"), ctx}|
    assert source =~ "# Tick\n"

    assert source =~
             ~s|def step(ctx, %Step{action_taken: "Tick"}) do\n    {:ok, todo!("Tick"), ctx}|

    assert {_module, []} = compile(source, MyApp.Trace)
  end

  test "names are quoted in the source" do
    manifest =
      synthetic([%{name: "Say", picks: :record, fields: [%{name: "a", type: ~S(str "#{1}")}]}])

    source = Scaffold.adapter_source(MyApp.Trace, manifest, synthetic_model())
    assert {_module, []} = compile(source, MyApp.Trace)
  end

  test "the test module" do
    counter =
      Scaffold.test_source(
        MyApp.CounterTraceTest,
        MyApp.CounterTrace,
        manifest(:counter),
        model(:counter)
      )

    assert counter =~ "defmodule MyApp.CounterTraceTest do\n  use ExUnit.Case, async: true\n"

    assert counter =~
             "  use AshQuint.Case, model: :counter, adapter: MyApp.CounterTrace, sensitivity: true\n"

    assert counter =~ "explore: true"
    assert counter =~ "ExUnit.start(exclude: [:quint_explore])"
    refute counter =~ "traces:"
    assert {_quoted, []} = Code.with_diagnostics(fn -> Code.string_to_quoted!(counter) end)

    race =
      Scaffold.test_source(MyApp.RaceTraceTest, MyApp.RaceTrace, manifest(:race), model(:race))

    assert race =~
             "use AshQuint.Case, model: :race, adapter: MyApp.RaceTrace, sensitivity: true\n"

    assert race =~ "traces: :sequential"
  end

  test "the test module of a model without random: explains what explore needs" do
    model = %{model(:counter) | random: nil}

    source =
      Scaffold.test_source(MyApp.CounterTraceTest, MyApp.CounterTrace, manifest(:counter), model)

    assert source =~ "explore: true needs random:"
  end
end
