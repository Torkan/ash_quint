defmodule Mix.Tasks.AshQuint.ExploreTest do
  # async: false: the task sets ASH_QUINT_EXPLORE* env vars and cds.
  use ExUnit.Case, async: false

  alias Mix.Tasks.AshQuint.Explore

  @moduletag :tmp_dir

  @env ~w(ASH_QUINT_EXPLORE ASH_QUINT_EXPLORE_RUNS ASH_QUINT_EXPLORE_SEED
          ASH_QUINT_EXPLORE_BUDGET ASH_QUINT_EXPLORE_FAILURES)

  setup %{tmp_dir: tmp_dir} do
    File.cp!("ash_quint.exs", Path.join(tmp_dir, "ash_quint.exs"))
    previous = Map.new(@env, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    %{root: tmp_dir}
  end

  # A runner that records its task, args and the explore env it sees.
  defp recorder do
    test = self()

    fn task, args ->
      send(test, {:run, task, args, Map.new(@env, &{&1, System.get_env(&1)})})
      :ok
    end
  end

  defp explore(root, argv, runner \\ recorder()),
    do: File.cd!(root, fn -> Explore.__run__(argv, runner) end)

  test "runs mix test for each model's explore test with the settings in the env",
       %{root: root} do
    System.put_env("ASH_QUINT_EXPLORE_RUNS", "3")
    System.delete_env("ASH_QUINT_EXPLORE_SEED")

    argv =
      ~w(counter race --runs 500 --seed 7 --budget 60 --failures 3)

    assert explore(root, argv) == :ok

    assert_received {:run, "test",
                     [
                       "--raise",
                       "--only",
                       "quint_explore:counter",
                       "--only",
                       "quint_explore:race"
                     ], env}

    assert env == %{
             "ASH_QUINT_EXPLORE" => "1",
             "ASH_QUINT_EXPLORE_RUNS" => "500",
             "ASH_QUINT_EXPLORE_SEED" => "7",
             "ASH_QUINT_EXPLORE_BUDGET" => "60",
             "ASH_QUINT_EXPLORE_FAILURES" => "3"
           }

    assert System.get_env("ASH_QUINT_EXPLORE_RUNS") == "3"
    assert System.get_env("ASH_QUINT_EXPLORE_SEED") == nil
    assert System.get_env("ASH_QUINT_EXPLORE") == nil
  end

  test "without models it runs every explore test", %{root: root} do
    Enum.each(@env, &System.delete_env/1)
    assert explore(root, []) == :ok

    assert_received {:run, "test", ["--raise", "--only", "quint_explore"], env}

    assert env == %{
             "ASH_QUINT_EXPLORE" => "1",
             "ASH_QUINT_EXPLORE_RUNS" => nil,
             "ASH_QUINT_EXPLORE_SEED" => nil,
             "ASH_QUINT_EXPLORE_BUDGET" => nil,
             "ASH_QUINT_EXPLORE_FAILURES" => nil
           }
  end

  test "an unknown model is an error", %{root: root} do
    assert_raise Mix.Error, "model :nope is not configured in ash_quint.exs", fn ->
      explore(root, ["nope"])
    end

    refute_received {:run, _task, _args, _env}
  end

  test "no explore test ran", %{root: root} do
    runner = fn "test", _args ->
      Mix.raise(~s(The --only option was given to "mix test" but no test was executed))
    end

    assert_raise Mix.Error,
                 "no explore test ran for counter, race; " <>
                   "add explore: true to the model's use AshQuint.Case",
                 fn -> explore(root, ~w(counter race), runner) end

    assert_raise Mix.Error,
                 "no explore test ran for any model; " <>
                   "add explore: true to the model's use AshQuint.Case",
                 fn -> explore(root, [], runner) end

    assert System.get_env("ASH_QUINT_EXPLORE") == nil
  end

  test "a failing test run is raised as it is, and the env restored", %{root: root} do
    runner = fn "test", _args -> Mix.raise(~s("mix test" failed)) end

    assert_raise Mix.Error, ~s("mix test" failed), fn -> explore(root, ["counter"], runner) end
    assert System.get_env("ASH_QUINT_EXPLORE") == nil
  end

  test "--runs 0 is an error", %{root: root} do
    for flag <- ~w(--runs --seed --budget --failures) do
      assert_raise Mix.Error, "#{flag} must be a positive integer", fn ->
        explore(root, [flag, "0"])
      end
    end

    assert_raise OptionParser.ParseError, fn -> explore(root, ["--runs", "x"]) end
    assert_raise OptionParser.ParseError, fn -> explore(root, ["--nope"]) end
    refute_received {:run, _task, _args, _env}
  end
end
