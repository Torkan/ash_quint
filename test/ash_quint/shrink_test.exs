defmodule AshQuint.ShrinkTest do
  use ExUnit.Case, async: true

  alias AshQuint.Config
  alias AshQuint.Gen
  alias AshQuint.ITF
  alias AshQuint.Manifest
  alias AshQuint.Shrink

  @config Config.load!()
  @counter Config.model!(@config, :counter)
  @race Config.model!(@config, :race)

  defp interface(model), do: Manifest.read!(Path.join(model.out, "manifest.json")).interface

  defp itf(model, file), do: Jason.decode!(File.read!(Path.join(model.out, file)))

  describe "render/1" do
    test "renders each shape" do
      assert Shrink.render(%{"#bigint" => "-3"}) == {:ok, "-3"}
      assert Shrink.render(7) == {:ok, "7"}
      assert Shrink.render("c1") == {:ok, ~s("c1")}
      assert Shrink.render(true) == {:ok, "true"}
      assert Shrink.render(false) == {:ok, "false"}
      assert Shrink.render(%{"#tup" => [1, "a"]}) == {:ok, ~s{(1, "a")}}
      assert Shrink.render(%{"tag" => "Init", "value" => %{"#tup" => []}}) == {:ok, "Init"}

      inc = %{"tag" => "Inc", "value" => %{"by" => %{"#bigint" => "2"}, "ctr" => "c1"}}
      assert Shrink.render(inc) == {:ok, ~s|Inc({ by: 2, ctr: "c1" })|}

      assert Shrink.render(%{"tag" => "Reset", "value" => "c1"}) == {:ok, ~s{Reset("c1")}}
      assert Shrink.render(%{"#set" => [1, 2]}) == {:ok, "Set(1, 2)"}
      assert Shrink.render(%{"#set" => []}) == {:ok, "Set()"}
      assert Shrink.render(%{"#map" => [["a", 1]]}) == {:ok, ~s{Map("a" -> 1)}}
      assert Shrink.render(%{"#map" => []}) == {:ok, "Map()"}
      assert Shrink.render([1, 2]) == {:ok, "[1, 2]"}
      assert Shrink.render([]) == {:ok, "[]"}
    end

    test "renders an integer Quint wrote as a bignumber.js object" do
      big = %{"s" => 1, "e" => 15, "c" => [10]}
      assert Shrink.render(big) == {:ok, "1000000000000000"}
    end

    test "refuses what it can't render" do
      for value <- [
            ~s(a"b),
            "a\\b",
            "a\nb",
            %{"#unserializable" => "x"},
            nil,
            1.5,
            %{"#tup" => [1]},
            %{"tag" => "not a name", "value" => 1},
            %{"not a name" => 1},
            [1, %{"#unserializable" => "x"}]
          ] do
        assert Shrink.render(value) == :error, inspect(value)
      end
    end
  end

  describe "calls/3" do
    test "by convention" do
      itf = itf(@counter, "random_1.itf.json")

      assert Shrink.calls(itf, interface(@counter), @counter) ==
               {:ok,
                [
                  ~s{inc("c1", 1)},
                  ~s{inc("c1", 2)},
                  ~s{inc("c1", 1)},
                  ~s{reset("c1")},
                  ~s{inc("c2", 2)},
                  ~s{peek("c1")},
                  ~s{peek("c2")},
                  ~s{reset("c2")},
                  ~s{peek("c1")},
                  ~s{peek("c2")}
                ]}

      assert length(itf["states"]) == 11
    end

    test "by convention, a unit action is called bare and a map pick is one argument" do
      interface = %AshQuint.Interface{
        actions: [
          %{name: "Init", picks: :unit},
          %{name: "Tick", picks: :unit},
          %{name: "Set", picks: :map, type: "str -> int"}
        ]
      }

      itf = %{
        "states" => [
          %{"lastAction" => %{"tag" => "Init", "value" => %{"#tup" => []}}},
          %{"lastAction" => %{"tag" => "Tick", "value" => %{"#tup" => []}}},
          %{"lastAction" => %{"tag" => "Set", "value" => %{"#map" => [["a", 1]]}}}
        ]
      }

      assert Shrink.calls(itf, interface, @counter) == {:ok, ["tick", ~s{set(Map("a" -> 1))}]}
    end

    test "reads the action at a nested path, under a qualified variable" do
      itf = %{
        "states" => [
          %{},
          %{"m::s" => %{"last" => %{"tag" => "Reset", "value" => "c1"}}}
        ]
      }

      model = %{@counter | action_path: ["s", "last"]}
      assert Shrink.calls(itf, interface(@counter), model) == {:ok, [~s{reset("c1")}]}
    end

    test "with apply" do
      itf = itf(@race, "random_1.itf.json")
      model = %{@race | shrink: [apply: "apply"]}

      assert Shrink.calls(itf, interface(@race), model) ==
               {:ok,
                [
                  ~s|apply(IncStart({ by: 2, op: "o2" }))|,
                  ~s|apply(IncStart({ by: 2, op: "o1" }))|,
                  ~s|apply(IncDone({ op: "o1" }))|,
                  ~s|apply(IncDone({ op: "o2" }))|
                ]}
    end

    test "the race by convention" do
      itf = itf(@race, "random_1.itf.json")

      assert Shrink.calls(itf, interface(@race), @race) ==
               {:ok,
                [
                  ~s{incStart("o2", 2)},
                  ~s{incStart("o1", 2)},
                  ~s{incDone("o1")},
                  ~s{incDone("o2")}
                ]}
    end

    test "names an unrenderable step" do
      itf = itf(@counter, "random_1.itf.json")
      itf = put_in(itf, ["states", Access.at(2), "lastAction", "value", "ctr"], ~s(a"b))

      assert Shrink.calls(itf, interface(@counter), @counter) ==
               {:error, ~S{step 2 (Inc): can't render "a\"b"}}

      with_apply = %{@counter | shrink: [apply: "apply"]}

      assert Shrink.calls(itf, interface(@counter), with_apply) ==
               {:error, ~S{step 2 (Inc): can't render "a\"b"}}
    end

    test "names a record pick missing a field" do
      itf = itf(@counter, "random_1.itf.json")
      itf = put_in(itf, ["states", Access.at(1), "lastAction", "value"], %{"ctr" => "c1"})

      assert Shrink.calls(itf, interface(@counter), @counter) ==
               {:error, ~s|step 1 (Inc): no field "by" in %{"ctr" => "c1"}|}
    end

    test "names an unknown action" do
      interface = interface(@counter)
      interface = %{interface | actions: Enum.reject(interface.actions, &(&1.name == "Peek"))}

      assert Shrink.calls(itf(@counter, "random_1.itf.json"), interface, @counter) ==
               {:error, ~s{step 6: action "Peek" isn't in the model interface}}
    end

    test "names a step without an action" do
      itf = %{"states" => [%{}, %{"lastAction" => 1}]}

      assert Shrink.calls(itf, interface(@counter), @counter) ==
               {:error, "step 1: no action variant at lastAction, got 1"}

      assert Shrink.calls(%{"states" => [%{}, %{}]}, interface(@counter), @counter) ==
               {:error, "step 1: no action variant at lastAction, got nil"}
    end
  end

  test "run_expression/2 chains the calls after init" do
    assert Shrink.run_expression(@counter, ["a", "b"]) == "init.then(a).then(b)"
    assert Shrink.run_expression(@counter, []) == "init"

    model = %{@counter | random: Keyword.put(@counter.random, :init, "start")}
    assert Shrink.run_expression(model, ["a"]) == "start.then(a)"
  end

  test "wrapper/3" do
    runs = [{"shrink_0", [~s{inc("c1", 2)}, ~s{reset("c1")}]}, {"shrink_1", [~s{reset("c1")}]}]

    assert Shrink.wrapper(@counter, "../../../../priv/examples/counter/model", runs) == """
           module ash_quint_shrink {
             import counter.* from "../../../../priv/examples/counter/model"
             run shrink_0 = init.then(inc("c1", 2)).then(reset("c1"))
             run shrink_1 = init.then(reset("c1"))
           }
           """
  end

  test "wrapper/3 imports shrink: [import: …]" do
    model = %{@counter | shrink: [import: "counter(CAP = 5)"]}

    assert Shrink.wrapper(model, "./model", [{"shrink_0", ["inc(1)"]}]) == """
           module ash_quint_shrink {
             import counter(CAP = 5).* from "./model"
             run shrink_0 = init.then(inc(1))
           }
           """
  end

  test "import_path/2" do
    model = "/r/priv/examples/counter/model.qnt"

    assert Shrink.import_path(model, "/r/_build/test/ash_quint/shrink/counter_x") ==
             "../../../../../priv/examples/counter/model"

    assert Shrink.import_path(model, "/r/priv/examples/counter/x") == "../model"
    assert Shrink.import_path(model, "/r/priv/examples/counter") == "./model"
    assert Shrink.import_path(model, "/r/priv") == "./examples/counter/model"
  end

  describe "shrink/3" do
    @describetag :tmp_dir

    # A toy model: init, then Act(p) for each candidate position p; `seen`
    # lists the positions so far. Quint (the stub runner) accepts a run
    # when every step keeps the steps it depends on (`deps`); the system
    # (the stub replay) fails with Act at the last step when the run keeps
    # every `bad` step and ends with the candidate's failing step, n - 1.
    @toy_interface %AshQuint.Interface{
      actions: [%{name: "Init", picks: :unit}, %{name: "Act", picks: :value, type: "int"}]
    }

    defp toy_model(opts \\ []) do
      struct!(
        AshQuint.Config.Model,
        [
          name: :toy,
          model: "toy/model.qnt",
          tests: "toy/model-tests.qnt",
          out: "toy/traces",
          on_missing_model: :fail,
          seed: 1,
          random: [main: "toy"],
          shrink: []
        ] ++ opts
      )
    end

    defp toy_config(root), do: %Config{quint: "0.33.1", root: root, models: %{}}

    defp big(n), do: %{"#bigint" => Integer.to_string(n)}

    defp toy_itf(positions, status \\ "ok") do
      init = %{
        "lastAction" => %{"tag" => "Init", "value" => %{"#tup" => []}},
        "lastResult" => %{"tag" => "Accepted", "value" => %{"#tup" => []}},
        "seen" => []
      }

      states =
        positions
        |> Enum.scan([], &(&2 ++ [&1]))
        |> Enum.map(fn seen ->
          %{
            "lastAction" => %{"tag" => "Act", "value" => big(List.last(seen))},
            "lastResult" => %{"tag" => "Accepted", "value" => %{"#tup" => []}},
            "seen" => Enum.map(seen, &big/1)
          }
        end)

      %{
        "#meta" => %{"format" => "ITF", "source" => "wrapper.qnt", "status" => status},
        "vars" => ["lastAction", "lastResult", "seen"],
        "states" => [init | states]
      }
    end

    defp candidate(n), do: Jason.encode!(toy_itf(Enum.to_list(0..(n - 1))))

    defp positions(binary) do
      %{"states" => states} = Jason.decode!(binary)
      Enum.map(List.last(states)["seen"], &String.to_integer(&1["#bigint"]))
    end

    defp valid?(deps, s), do: Enum.all?(deps, fn {i, j} -> j not in s or i in s end)

    defp fails?(bad, s, n), do: Enum.all?(bad, &(&1 in s)) and List.last(s) == n - 1

    # The runs of the wrapper the runner was given, as {name, positions}.
    defp runs(args) do
      wrapper = File.read!(Enum.at(args, Enum.find_index(args, &(&1 == "test")) + 1))

      ~r/run (shrink_\d+) = init((?:\.then\(act\(\d+\)\))*)/
      |> Regex.scan(wrapper)
      |> Enum.map(fn [_, name, calls] ->
        {name, ~r/\d+/ |> Regex.scan(calls) |> Enum.map(&String.to_integer(hd(&1)))}
      end)
    end

    defp out_pattern(args) do
      Enum.find_value(args, fn
        "--out-itf=" <> pattern -> pattern
        _arg -> nil
      end)
    end

    # The stub Quint: each run's ITF, `ok` when valid. `write` decides per
    # call (counted from 0) whether to write anything; `tamper` changes a
    # written trace.
    defp runner(deps, opts \\ []) do
      write = Keyword.get(opts, :write, fn _call -> true end)
      tamper = Keyword.get(opts, :tamper, fn _name, itf -> itf end)
      output = Keyword.get(opts, :output, "")
      test = self()

      fn exe, args, run_opts ->
        call = Process.get(:quint_calls, 0)
        Process.put(:quint_calls, call + 1)
        runs = runs(args)
        pattern = out_pattern(args)
        send(test, {:quint, exe, args, run_opts, runs, File.dir?(Path.dirname(pattern))})

        if write.(call), do: write_runs(runs, pattern, deps, tamper)

        {output, if(Enum.all?(runs, fn {_, p} -> valid?(deps, p) end), do: 0, else: 1)}
      end
    end

    defp write_runs(runs, pattern, deps, tamper) do
      for {name, positions} <- runs do
        status = if valid?(deps, positions), do: "ok", else: "violation"
        itf = tamper.(name, toy_itf(positions, status))
        File.write!(String.replace(pattern, "{test}", name), Jason.encode!(itf))
      end
    end

    defp replay(bad, n) do
      fn binary ->
        s = positions(binary)
        if fails?(bad, s, n), do: {:failed, length(s), "Act", "failed at #{length(s)}"}, else: :ok
      end
    end

    defp shrink(tmp_dir, n, opts) do
      model = Keyword.get(opts, :model, toy_model())

      Shrink.shrink(candidate(n), "Act",
        config: toy_config(tmp_dir),
        model: model,
        interface: @toy_interface,
        runner: Keyword.fetch!(opts, :runner),
        replay: Keyword.fetch!(opts, :replay),
        keep?: Keyword.get(opts, :keep?, fn _binary -> true end),
        dir: Path.join(tmp_dir, "shrink")
      )
    end

    defp quint_calls do
      receive do
        {:quint, _exe, args, _opts, runs, _dir?} -> [{args, runs} | quint_calls()]
      after
        0 -> []
      end
    end

    test "shrinks to the failing step alone", %{tmp_dir: tmp_dir} do
      assert {:ok, binary, shrunk} = shrink(tmp_dir, 6, runner: runner([]), replay: replay([], 6))
      assert %{steps: 1, run: "init.then(act(5))", message: "failed at 1", stopped: nil} = shrunk
      assert shrunk.rounds >= 1

      json = Jason.decode!(binary)
      assert json["#meta"]["source"] == "toy/model.qnt"
      assert json["#meta"]["status"] == "ok"
      assert json["states"] == toy_itf([5])["states"]
    end

    test "keeps a dependency", %{tmp_dir: tmp_dir} do
      assert {:ok, _binary, %{run: "init.then(act(0)).then(act(2)).then(act(5))", steps: 3}} =
               shrink(tmp_dir, 6, runner: runner([{2, 5}]), replay: replay([0], 6))
    end

    test "the shrunk trace is normalized, in Quint's key order", %{tmp_dir: tmp_dir} do
      inner = runner([])

      runner = fn exe, args, opts ->
        result = inner.(exe, args, opts)

        for path <- Path.wildcard(Path.join(Path.dirname(out_pattern(args)), "*.itf.json")) do
          json = Jason.decode!(File.read!(path))
          meta = Map.merge(json["#meta"], %{"description" => "d", "timestamp" => 1})

          ordered =
            Jason.OrderedObject.new([
              {"vars", json["vars"]},
              {"#meta", meta},
              {"states", json["states"]}
            ])

          File.write!(path, Jason.encode!(ordered))
        end

        result
      end

      assert {:ok, binary, _shrunk} = shrink(tmp_dir, 6, runner: runner, replay: replay([], 6))

      assert %Jason.OrderedObject{values: values} =
               Jason.decode!(binary, objects: :ordered_objects)

      assert Enum.map(values, &elem(&1, 0)) == ["vars", "#meta", "states"]
      meta = Jason.decode!(binary)["#meta"]
      assert meta == %{"format" => "ITF", "source" => "toy/model.qnt", "status" => "ok"}
    end

    test "nothing can go", %{tmp_dir: tmp_dir} do
      chain = [{0, 1}, {1, 2}, {2, 3}, {3, 4}, {4, 5}]

      assert shrink(tmp_dir, 6, runner: runner(chain), replay: replay([], 6)) ==
               {:not_shrunk, "no step could be removed"}

      assert Enum.map(quint_calls(), fn {_args, runs} -> length(runs) end) == [1, 3, 5]
    end

    test "the first round removes the first chunk", %{tmp_dir: tmp_dir} do
      assert {:ok, _binary, shrunk} =
               shrink(tmp_dir, 6,
                 model: toy_model(shrink: [rounds: 1]),
                 runner: runner([]),
                 replay: replay([2, 3, 4], 6)
               )

      assert %{run: "init.then(act(2)).then(act(3)).then(act(4)).then(act(5))", rounds: 1} =
               shrunk
    end

    test "invariants hold through the driver", %{tmp_dir: tmp_dir} do
      pairs = for i <- 0..3, j <- 0..3, i < j, do: {i, j}

      subsets = fn list ->
        Enum.reduce(list, [[]], fn x, acc -> acc ++ Enum.map(acc, &[x | &1]) end)
      end

      for deps <- subsets.(pairs), bad <- subsets.([0, 1, 2]) do
        result = shrink(tmp_dir, 4, runner: runner(deps), replay: replay(bad, 4))
        oracle = inspect({deps, bad, result})

        case result do
          {:ok, binary, shrunk} ->
            s = positions(binary)
            assert valid?(deps, s), "keptValid: " <> oracle
            assert fails?(bad, s, 4), "keptFails: " <> oracle
            assert s == Enum.sort(Enum.uniq(s)) and List.last(s) == 3, "keptOrdered: " <> oracle
            assert shrunk.rounds <= 20, "roundsBounded: " <> oracle

            for i <- 0..(length(s) - 2)//1, shrunk.rounds < 20 do
              r = List.delete_at(s, i)
              refute valid?(deps, r) and fails?(bad, r, 4), "doneMinimal: " <> oracle
            end

          {:not_shrunk, "no step could be removed"} ->
            s = [0, 1, 2, 3]

            for i <- 0..2 do
              r = List.delete_at(s, i)
              refute valid?(deps, r) and fails?(bad, r, 4), "doneMinimal: " <> oracle
            end
        end
      end
    end

    test "an earlier failure with the same action cuts the reduction", %{tmp_dir: tmp_dir} do
      replay = fn binary ->
        s = positions(binary)

        case Enum.find_index(s, &(&1 == 1)) do
          nil -> :ok
          i -> {:failed, i + 1, "Act", "failed at #{i + 1}"}
        end
      end

      assert {:ok, binary, %{run: "init.then(act(1))", steps: 1}} =
               shrink(tmp_dir, 6, runner: runner([]), replay: replay)

      assert Jason.decode!(binary)["states"] == toy_itf([1])["states"]
    end

    test "a failure with another action isn't accepted", %{tmp_dir: tmp_dir} do
      replay = fn _binary -> {:failed, 1, "Other", "other"} end

      assert shrink(tmp_dir, 6, runner: runner([]), replay: replay) ==
               {:not_shrunk, "no step could be removed"}
    end

    test "a raising replay isn't accepted", %{tmp_dir: tmp_dir} do
      replay = fn _binary -> {:raised, "boom"} end

      assert shrink(tmp_dir, 6, runner: runner([]), replay: replay) ==
               {:not_shrunk, "no step could be removed"}
    end

    test "keep? filters reductions", %{tmp_dir: tmp_dir} do
      test = self()

      keep? = fn binary ->
        send(test, {:keep?, positions(binary)})
        false
      end

      assert shrink(tmp_dir, 6, runner: runner([]), replay: replay([], 6), keep?: keep?) ==
               {:not_shrunk, "no step could be removed"}

      assert_received {:keep?, [2, 3, 4, 5]}
    end

    test "round 0 states must match", %{tmp_dir: tmp_dir} do
      tamper = fn
        "shrink_0", itf -> put_in(itf, ["states", Access.at(4), "seen"], [])
        _name, itf -> itf
      end

      assert shrink(tmp_dir, 6, runner: runner([], tamper: tamper), replay: replay([], 6)) ==
               {:not_shrunk,
                ~s(the model's run differs from the trace at step 4, variable "seen")}
    end

    test "round 0 that can't be decoded", %{tmp_dir: tmp_dir} do
      tamper = fn _name, itf ->
        put_in(itf, ["states", Access.at(1), "seen"], %{"#unserializable" => "x"})
      end

      assert shrink(tmp_dir, 6, runner: runner([], tamper: tamper), replay: replay([], 6)) ==
               {:not_shrunk,
                "the model's run can't be read: shrink_0 at $.states[1].seen: unknown ITF form #unserializable"}
    end

    test "round 0 with fewer states", %{tmp_dir: tmp_dir} do
      tamper = fn _name, itf -> update_in(itf["states"], &Enum.take(&1, 3)) end

      assert shrink(tmp_dir, 6, runner: runner([], tamper: tamper), replay: replay([], 6)) ==
               {:not_shrunk,
                ~s(the model's run differs from the trace at step 3, variable "lastAction")}
    end

    test "round 0 not enabled", %{tmp_dir: tmp_dir} do
      output =
        "\n  ash_quint_shrink\n    1) shrink_0 failed\n\nerror: [QNT513] Action not enabled\n"

      assert shrink(tmp_dir, 6,
               runner: runner([{0, 5}, {1, 5}, {9, 0}], output: output),
               replay: replay([], 6)
             ) ==
               {:not_shrunk,
                "Quint doesn't accept the trace's calls as a run: error: [QNT513] Action not enabled"}
    end

    test "round 0 not enabled, without a QNT line", %{tmp_dir: tmp_dir} do
      output = "\n  ash_quint_shrink\n    1) shrink_0 failed\n"

      assert shrink(tmp_dir, 6, runner: runner([{9, 0}], output: output), replay: replay([], 6)) ==
               {:not_shrunk, "Quint doesn't accept the trace's calls as a run: ash_quint_shrink"}
    end

    test "quint test writing nothing", %{tmp_dir: tmp_dir} do
      runner =
        runner([], write: fn _ -> false end, output: "\nerror: [QNT404] Name 'act' not found\n")

      assert shrink(tmp_dir, 6, runner: runner, replay: replay([], 6)) ==
               {:not_shrunk,
                "quint test failed: error: [QNT404] Name 'act' not found " <>
                  ~s{(if random's main is an instance module, set shrink: [import: "<module>(<constants>)"])}}
    end

    test "quint test writing nothing, with import: set, gives no hint", %{tmp_dir: tmp_dir} do
      runner =
        runner([], write: fn _ -> false end, output: "\nerror: [QNT404] Name 'act' not found\n")

      assert shrink(tmp_dir, 6,
               model: toy_model(shrink: [import: "toy(N = 1)"]),
               runner: runner,
               replay: replay([], 6)
             ) == {:not_shrunk, "quint test failed: error: [QNT404] Name 'act' not found"}
    end

    test "Quint that can't be run", %{tmp_dir: tmp_dir} do
      runner = fn _exe, _args, _opts -> :erlang.error(:enoent) end

      assert shrink(tmp_dir, 6, runner: runner, replay: replay([], 6)) ==
               {:not_shrunk,
                "quint test failed: could not run Quint (npx --yes @informalsystems/quint@0.33.1): executable not found"}
    end

    test "a later round writing nothing stops the loop", %{tmp_dir: tmp_dir} do
      runner = runner([], write: &(&1 <= 1), output: "\nerror: out of memory\nmore\n")

      assert {:ok, _binary, shrunk} =
               shrink(tmp_dir, 6, runner: runner, replay: replay([2, 3, 4], 6))

      assert %{
               run: "init.then(act(2)).then(act(3)).then(act(4)).then(act(5))",
               rounds: 1,
               stopped: "quint test wrote no runs: error: out of memory"
             } = shrunk

      assert length(quint_calls()) == 3
    end

    test "round 1 writing nothing isn't shrunk", %{tmp_dir: tmp_dir} do
      runner = runner([], write: &(&1 == 0), output: "\nerror: out of memory\nmore\n")

      assert shrink(tmp_dir, 6, runner: runner, replay: replay([], 6)) ==
               {:not_shrunk, "quint test wrote no runs: error: out of memory"}

      assert length(quint_calls()) == 2
    end

    test "flaky confirmation", %{tmp_dir: tmp_dir} do
      # The confirmation is the second replay of the accepted reduction.
      inner = replay([], 6)

      replay = fn binary ->
        s = positions(binary)
        seen = Process.get(:replayed, MapSet.new())
        Process.put(:replayed, MapSet.put(seen, s))
        if MapSet.member?(seen, s), do: :ok, else: inner.(binary)
      end

      assert shrink(tmp_dir, 6, runner: runner([]), replay: replay) ==
               {:not_shrunk, "did not reproduce"}
    end

    test "one step isn't shrunk", %{tmp_dir: tmp_dir} do
      assert shrink(tmp_dir, 1, runner: runner([]), replay: replay([], 1)) ==
               {:not_shrunk, "the failing step is the only step"}

      assert quint_calls() == []
      refute File.exists?(Path.join(tmp_dir, "shrink"))
    end

    test "a step that can't be called isn't shrunk", %{tmp_dir: tmp_dir} do
      model = toy_model()

      assert Shrink.shrink(candidate(3), "Act",
               config: toy_config(tmp_dir),
               model: model,
               interface: %AshQuint.Interface{actions: []},
               runner: runner([]),
               replay: replay([], 3),
               keep?: fn _ -> true end,
               dir: Path.join(tmp_dir, "shrink")
             ) == {:not_shrunk, ~s(step 1: action "Act" isn't in the model interface)}

      assert quint_calls() == []
    end

    test "the work dir is created first and removed", %{tmp_dir: tmp_dir} do
      assert {:ok, _, _} = shrink(tmp_dir, 6, runner: runner([]), replay: replay([], 6))

      assert_received {:quint, _exe, args, opts, _runs, true}
      assert opts[:cd] == tmp_dir

      [work] =
        Enum.uniq(
          Enum.map([args | Enum.map(quint_calls(), &elem(&1, 0))], &Path.dirname(out_pattern(&1)))
        )

      assert Path.dirname(work) == Path.join(tmp_dir, "shrink")
      assert Path.basename(work) =~ ~r/\Atoy_[0-9a-f]{16}\z/
      assert File.ls!(Path.join(tmp_dir, "shrink")) == []
    end

    test "the quint test command", %{tmp_dir: tmp_dir} do
      assert {:ok, _, _} = shrink(tmp_dir, 3, runner: runner([]), replay: replay([], 3))

      assert_received {:quint, "npx", args, _opts, [{"shrink_0", [0, 1, 2]}], true}
      work = Path.dirname(out_pattern(args))

      assert args == [
               "--yes",
               "@informalsystems/quint@0.33.1",
               "test",
               Path.join(work, "ash_quint_shrink.qnt"),
               "--main=ash_quint_shrink",
               "--match=^shrink_[0-9]+$",
               "--seed=1",
               "--out-itf=#{work}/{test}.itf.json"
             ]
    end

    test "the wrapper imports the model relative to the work dir", %{tmp_dir: tmp_dir} do
      test = self()
      inner = runner([])

      runner = fn exe, args, opts ->
        send(test, {:wrapper, File.read!(Enum.at(args, 3))})
        inner.(exe, args, opts)
      end

      assert {:ok, _, _} = shrink(tmp_dir, 3, runner: runner, replay: replay([], 3))
      assert_received {:wrapper, wrapper}

      assert wrapper == """
             module ash_quint_shrink {
               import toy.* from "../../toy/model"
               run shrink_0 = init.then(act(0)).then(act(1)).then(act(2))
             }
             """
    end

    test "backend is passed", %{tmp_dir: tmp_dir} do
      model = toy_model(backend: "rust")

      assert {:ok, _, _} =
               shrink(tmp_dir, 6, model: model, runner: runner([]), replay: replay([], 6))

      calls = quint_calls()
      assert length(calls) > 1
      assert Enum.all?(calls, fn {args, _} -> "--backend=rust" in args end)
    end
  end

  describe "round 0 with Quint" do
    # Real Quint through npx: excluded by default, run with
    # `mix test --only quint_cli`.
    @describetag :quint_cli
    @describetag :tmp_dir
    @describetag timeout: 300_000

    # The calls of each committed random trace of `model` as one run each,
    # in one quint test: each run's states, decoded, and the trace's.
    defp round_zero(model, tmp_dir) do
      files = model.out |> Path.join("random_*.itf.json") |> Path.wildcard() |> Enum.sort()
      assert files != []
      interface = interface(model)

      runs =
        files
        |> Enum.with_index()
        |> Enum.map(fn {file, k} ->
          assert {:ok, calls} = Shrink.calls(Jason.decode!(File.read!(file)), interface, model)
          {"shrink_#{k}", calls}
        end)

      assert {output, statuses} = quint_wrapper(model, runs, tmp_dir)
      assert Enum.all?(statuses, &(&1 == "ok")), output

      for {file, {name, _calls}} <- Enum.zip(files, runs) do
        run = Jason.decode!(File.read!(Path.join(tmp_dir, "#{name}.itf.json")))
        {states(file), ITF.decode!(run, name).states}
      end
    end

    defp states(file), do: ITF.read!(file).states

    test "round 0 reproduces the committed counter traces", %{tmp_dir: tmp_dir} do
      for {expected, actual} <- round_zero(@counter, tmp_dir), do: assert(actual == expected)
    end

    test "round 0 reproduces the committed race traces", %{tmp_dir: tmp_dir} do
      for {expected, actual} <- round_zero(@race, tmp_dir), do: assert(actual == expected)
    end

    # The wrapper of `runs` for `model`, run with one quint test: Quint's
    # output and each run's #meta.status (nil when not written).
    defp quint_wrapper(model, runs, tmp_dir) do
      wrapper = Path.join(tmp_dir, "ash_quint_shrink.qnt")
      import = Shrink.import_path(Path.expand(model.model), tmp_dir)
      File.write!(wrapper, Shrink.wrapper(model, import, runs))

      args =
        ["test", wrapper, "--main=ash_quint_shrink", "--match=^shrink_[0-9]+$", "--seed=1"] ++
          Gen.backend_args(model) ++ ["--out-itf=#{tmp_dir}/{test}.itf.json"]

      runner = fn exe, args, opts -> System.cmd(exe, args, opts ++ [stderr_to_stdout: true]) end
      {:ok, output, _status} = Gen.run_quint(@config, args, runner)

      statuses =
        for {name, _calls} <- runs do
          case File.read(Path.join(tmp_dir, "#{name}.itf.json")) do
            {:ok, binary} -> Jason.decode!(binary)["#meta"]["status"]
            {:error, _reason} -> nil
          end
        end

      {output, statuses}
    end

    test "an instance module as main needs shrink: [import: …]", %{tmp_dir: tmp_dir} do
      model = %{
        @counter
        | model: "test/fixtures/shrink/instance/model.qnt",
          random: Keyword.put(@counter.random, :main, "counter_app")
      }

      runs = [{"shrink_0", ["inc(1)", "inc(2)"]}]

      assert {output, [nil]} = quint_wrapper(model, runs, tmp_dir)
      assert output =~ "QNT404"

      model = %{model | shrink: [import: "counter(CAP = 5)"]}
      assert {_output, ["ok"]} = quint_wrapper(model, runs, tmp_dir)
    end

    test "round 0 with apply", %{tmp_dir: tmp_dir} do
      model = %{
        @race
        | model: "test/fixtures/shrink/race_apply/model.qnt",
          shrink: [apply: "apply"]
      }

      for {expected, actual} <- round_zero(model, tmp_dir), do: assert(actual == expected)
    end
  end
end
