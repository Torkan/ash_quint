defmodule AshQuint.Shrink.LoopTest do
  # Derived from models/practices/model.qnt (module shrink) and its
  # scenario tests in models/practices/model-tests.qnt.
  use ExUnit.Case, async: true

  alias AshQuint.Config
  alias AshQuint.Gen
  alias AshQuint.ITF
  alias AshQuint.Shrink.Loop

  # The model's oracles: a run is valid when every step keeps the steps it
  # depends on, and fails when it keeps every bad step and ends at the
  # failing step n - 1.
  defp valid?(deps, s) do
    set = MapSet.new(s)
    Enum.all?(deps, fn {i, j} -> not MapSet.member?(set, j) or MapSet.member?(set, i) end)
  end

  defp fails?(bad, s, n),
    do: MapSet.subset?(MapSet.new(bad), MapSet.new(s)) and List.last(s) == n - 1

  defp first_accepted(loop, deps, bad, n) do
    Enum.find_value(Loop.removals(loop), fn {_p, s} ->
      if valid?(deps, s) and fails?(bad, s, n), do: s
    end)
  end

  # Drives the loop until it's done; every state, the first one included.
  defp run(n, budget, deps, bad), do: drive([Loop.new(n, budget)], deps, bad, n)

  defp drive([%Loop{done: true} | _] = states, _deps, _bad, _n), do: Enum.reverse(states)

  defp drive([loop | _] = states, deps, bad, n),
    do: drive([Loop.advance(loop, first_accepted(loop, deps, bad, n)) | states], deps, bad, n)

  defp pairs(n), do: for(i <- 0..(n - 1), j <- 0..(n - 1), i < j, do: {i, j})

  defp subsets([]), do: [[]]
  defp subsets([x | rest]), do: Enum.flat_map(subsets(rest), &[&1, [x | &1]])

  defp oracles(n),
    do: for(deps <- subsets(pairs(n)), bad <- subsets(Enum.to_list(0..(n - 2))), do: {deps, bad})

  defp minimal?(%Loop{kept: kept}, deps, bad, n) do
    Enum.all?(0..(length(kept) - 2)//1, fn i ->
      s = List.delete_at(kept, i)
      not (valid?(deps, s) and fails?(bad, s, n))
    end)
  end

  # The message is built only on failure: the sweeps check ~100 000 states.
  defp check(true, _invariant, _deps, _bad, _loop), do: :ok

  defp check(false, invariant, deps, bad, loop),
    do: flunk("#{invariant} broken: deps #{inspect(deps)}, bad #{inspect(bad)}, #{inspect(loop)}")

  defp assert_invariants(n, budget, deps, bad) do
    states = run(n, budget, deps, bad)

    for loop <- states do
      check(valid?(deps, loop.kept), "keptValid", deps, bad, loop)
      check(fails?(bad, loop.kept, n), "keptFails", deps, bad, loop)
      check(List.last(loop.kept) == n - 1, "keptOrdered", deps, bad, loop)
      check(loop.kept == Enum.sort(Enum.uniq(loop.kept)), "keptOrdered", deps, bad, loop)
      check(loop.chunk in 1..n, "chunkBounded", deps, bad, loop)
      check(loop.rounds <= budget, "roundsBounded", deps, bad, loop)

      if loop.done and not loop.exhausted do
        check(minimal?(loop, deps, bad, n), "doneMinimal", deps, bad, loop)
      end
    end

    List.last(states)
  end

  describe "the model's scenario tests" do
    test "aloneTest" do
      final = List.last(run(6, 50, [], []))
      assert final.kept == [5]
      assert final.done
      refute final.exhausted
    end

    test "dependencyTest" do
      final = List.last(run(6, 50, [{2, 5}], [0]))
      assert final.done
      assert final.kept == [0, 2, 5]
    end

    test "chainTest" do
      states = run(6, 50, [{0, 1}, {1, 2}, {2, 3}, {3, 4}, {4, 5}], [])
      assert length(states) == 3
      final = List.last(states)
      assert final.done
      assert final.kept == [0, 1, 2, 3, 4, 5]
      assert final.chunk == 1
      assert final.rounds == 2
    end

    test "firstChunkTest" do
      loop = Loop.new(6, 50)
      loop = Loop.advance(loop, first_accepted(loop, [], [2, 3, 4], 6))
      assert loop.kept == [2, 3, 4, 5]
      assert loop.chunk == 2
      refute loop.done
    end
  end

  test "new/2 starts with every position and half the prefix as chunk" do
    assert Loop.new(6, 20) == %Loop{
             kept: [0, 1, 2, 3, 4, 5],
             chunk: 2,
             rounds: 0,
             budget: 20,
             done: false,
             exhausted: false
           }

    assert Loop.new(2, 20).chunk == 1
  end

  test "removals/1 at chunk 2" do
    assert Loop.removals(Loop.new(6, 50)) == [
             {0, [2, 3, 4, 5]},
             {2, [0, 1, 4, 5]},
             {4, [0, 1, 2, 3, 5]}
           ]
  end

  test "removals/1 never removes the last kept step" do
    loop = %{Loop.new(6, 50) | kept: [1, 3, 5], chunk: 2}
    assert Loop.removals(loop) == [{0, [5]}]
  end

  test "advance/2 narrows a chunk wider than the new prefix and halves on a failed round" do
    loop = %{Loop.new(10, 50) | chunk: 4}
    assert Loop.advance(loop, [7, 8, 9]).chunk == 1
    assert Loop.advance(loop, [2, 3, 4, 5, 6, 9]).chunk == 4
    assert Loop.advance(loop, nil).chunk == 2
    refute Loop.advance(loop, nil).done
  end

  test "advance/2 ends the loop with an empty prefix" do
    loop = Loop.advance(Loop.new(6, 50), [5])
    assert %Loop{kept: [5], done: true, exhausted: false, rounds: 1} = loop
  end

  test "advance/2 ends the loop exhausted on the last round of the budget" do
    loop = Loop.advance(Loop.new(6, 1), [2, 3, 4, 5])
    assert %Loop{done: true, exhausted: true, rounds: 1} = loop

    # A natural end on the last round isn't exhausted.
    loop = Loop.advance(%{Loop.new(6, 1) | chunk: 1}, nil)
    assert %Loop{done: true, exhausted: false} = loop
  end

  test "advance/2 refuses a loop that is done" do
    assert_raise FunctionClauseError, fn -> Loop.advance(Loop.new(1, 20), nil) end
  end

  test "invariants hold for every oracle of 4 steps" do
    oracles = oracles(4)
    assert length(oracles) == 512
    for {deps, bad} <- oracles, do: assert(assert_invariants(4, 50, deps, bad).done)
  end

  test "invariants hold for every oracle of 5 steps" do
    oracles = oracles(5)
    assert length(oracles) == 16_384
    for {deps, bad} <- oracles, do: assert(assert_invariants(5, 50, deps, bad).done)
  end

  test "a tight budget ends exhausted, and doneMinimal holds otherwise" do
    finals = for {deps, bad} <- oracles(5), do: assert_invariants(5, 2, deps, bad)
    assert Enum.all?(finals, &(&1.done and &1.rounds <= 2))
    assert Enum.any?(finals, & &1.exhausted)
  end

  test "the witnesses are reached" do
    finals = for {deps, bad} <- oracles(5), do: {bad, List.last(run(5, 50, deps, bad))}

    # witShrunk
    assert Enum.any?(finals, fn {_, l} -> l.done and length(l.kept) < 5 and not l.exhausted end)
    # witToFailingStepOnly
    assert Enum.any?(finals, fn {_, l} -> l.done and l.kept == [4] end)
    # witKeptByDependency
    assert Enum.any?(finals, fn {bad, l} ->
             l.done and Enum.any?(l.kept, &(&1 not in bad and &1 != 4))
           end)
  end

  test "rounds stay within 6 for 6 steps" do
    :rand.seed(:exsss, {1, 2, 3})
    pairs = pairs(6)

    for _ <- 1..2000 do
      deps = Enum.filter(pairs, fn _ -> :rand.uniform(2) == 1 end)
      bad = Enum.filter(0..4, fn _ -> :rand.uniform(2) == 1 end)
      final = assert_invariants(6, 50, deps, bad)
      check(final.rounds <= 6, "rounds <= 6", deps, bad, final)
    end
  end

  test "one step is done at once" do
    loop = Loop.new(1, 20)
    assert loop.done
    refute loop.exhausted
    assert Loop.removals(loop) == []
  end

  describe "the model's traces" do
    @describetag :quint_cli
    @describetag :tmp_dir
    @describetag timeout: 300_000

    test "the loop follows the model's traces", %{tmp_dir: tmp_dir} do
      config = Config.load!()

      args = [
        "run",
        "models/practices/model.qnt",
        "--main=shrink4",
        "--max-steps=12",
        "--max-samples=50",
        "--n-traces=50",
        "--seed=7",
        "--out-itf=#{tmp_dir}/loop_{seq}.itf.json"
      ]

      runner = fn cmd, args, opts -> System.cmd(cmd, args, opts ++ [stderr_to_stdout: true]) end
      assert {:ok, output, 0} = Gen.run_quint(config, args, runner)

      traces = Path.wildcard(Path.join(tmp_dir, "loop_*.itf.json"))
      assert length(traces) == 50, output

      for path <- traces do
        [first | rest] = ITF.read!(path).states
        deps = MapSet.to_list(first["deps"])
        bad = MapSet.to_list(first["bad"])

        Enum.reduce(rest, follow(Loop.new(4, 50), first, path), fn state, loop ->
          loop =
            if state["rounds"] > loop.rounds,
              do: Loop.advance(loop, first_accepted(loop, deps, bad, 4)),
              else: loop

          follow(loop, state, path)
        end)
      end
    end
  end

  defp follow(loop, state, path) do
    model = Map.take(state, ["kept", "chunk", "rounds", "done", "exhausted"])

    assert model == %{
             "kept" => loop.kept,
             "chunk" => loop.chunk,
             "rounds" => loop.rounds,
             "done" => loop.done,
             "exhausted" => loop.exhausted
           },
           "#{path}: #{inspect(state)}"

    loop
  end
end
