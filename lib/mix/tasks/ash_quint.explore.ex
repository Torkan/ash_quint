defmodule Mix.Tasks.AshQuint.Explore do
  @shortdoc "Replays fresh Quint traces of the models against the system"

  @moduledoc """
  Runs the explore tests of the models: each replays fresh `quint run`
  traces against the system and reports every failure as a candidate
  regression trace (see `AshQuint.Explore`).

      MIX_ENV=test mix ash_quint.explore [model ...] [--runs N] [--seed S]
        [--budget SECONDS] [--failures N]

  An explore test is the `"explore <model>"` test that `AshQuint.Case`
  defines with `explore: true`, tagged `quint_explore: <model>` and
  excluded from the suite in `test/test_helper.exs`. This task checks the
  models against `ash_quint.exs`, sets the session's environment
  variables and runs `mix test --raise --only quint_explore:<model>` (one
  `--only` per model; `--only quint_explore` without models):

    * `ASH_QUINT_EXPLORE=1` — lets the explore tests run;
    * `--runs` → `ASH_QUINT_EXPLORE_RUNS` — fresh traces per model
      (default 100);
    * `--seed` → `ASH_QUINT_EXPLORE_SEED` — the base seed (default random);
    * `--budget` → `ASH_QUINT_EXPLORE_BUDGET` — wall-clock seconds, after
      which no new batch starts (default none);
    * `--failures` → `ASH_QUINT_EXPLORE_FAILURES` — stop after this many
      failures (default 1).

  The variables are restored afterwards. A failing explore test fails the
  task, listing each candidate and the `mix ash_quint.promote` command
  that commits it. When no explore test runs, the task fails asking for
  `explore: true`.

  Run it as `MIX_ENV=test mix ash_quint.explore` (or add
  `"ash_quint.explore": :test` to `preferred_envs`). It is a convenience:
  `ASH_QUINT_EXPLORE=1 mix test --only quint_explore` runs the same
  tests.
  """

  use Mix.Task

  alias AshQuint.Config

  @flags [runs: "RUNS", seed: "SEED", budget: "BUDGET", failures: "FAILURES"]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(argv), do: __run__(argv, &Mix.Task.run/2)

  @doc false
  @spec __run__([String.t()], (String.t(), [String.t()] -> term())) :: :ok
  def __run__(argv, runner) do
    switches = Enum.map(@flags, fn {flag, _name} -> {flag, :integer} end)
    {opts, names} = OptionParser.parse!(argv, strict: switches)

    for {flag, value} <- opts, value < 1 do
      Mix.raise("--#{flag} must be a positive integer")
    end

    models = Config.select!(Config.load!(), names)

    only =
      case names do
        [] -> ["--only", "quint_explore"]
        _names -> Enum.flat_map(models, &["--only", "quint_explore:#{&1.name}"])
      end

    env =
      [{"ASH_QUINT_EXPLORE", "1"}] ++
        for {flag, name} <- @flags, value = opts[flag] do
          {"ASH_QUINT_EXPLORE_" <> name, Integer.to_string(value)}
        end

    with_env(env, fn -> run_tests(runner, ["--raise" | only], names) end)

    :ok
  end

  defp run_tests(runner, args, names) do
    runner.("test", args)
  rescue
    error in Mix.Error ->
      if error.message =~ "but no test was executed" do
        which = if names == [], do: "any model", else: Enum.join(names, ", ")

        Mix.raise(
          "no explore test ran for #{which}; " <>
            "add explore: true to the model's use AshQuint.Case"
        )
      else
        reraise error, __STACKTRACE__
      end
  end

  defp with_env(env, fun) do
    previous = Enum.map(env, fn {name, _value} -> {name, System.get_env(name)} end)
    Enum.each(env, fn {name, value} -> System.put_env(name, value) end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end
end
