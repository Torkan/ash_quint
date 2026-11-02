defmodule AshQuint.Sensitivity do
  @moduledoc """
  Checks that passing replays mean something: mutants of the replay must
  fail.

  `check/3` replays every trace clean, then picks two kinds of mutant from
  the clean reports:

    * **Perturbed expectation.** For each projected key, the first synced
      step (traces in the given order, steps in order) whose expected value
      differs from the previous synced step's has that value replaced with
      `{:ash_quint_mutated, key}`. The replay must fail at that step, on
      that key. The first synced step of a trace is compared with the
      initial state's expected value right after `init/2`.
    * **Dropped call.** For each action, the first step that returned
      `{:ok, …}` and changed the expected state is replayed as a skip, with
      no system call. The replay must fail at that step or a later one.
      A rejected call, or any call that changes nothing, can't be detected
      when dropped, so it isn't chosen.

  A key whose expected value never changes is reported as untested
  (`{:key, key}`), and so is an action with `{:ok, …}` steps none of which
  changes the state (`{:call, action}`): the traces never show that the
  projection observes them. Actions whose steps are all skipped make no
  system call and aren't considered.

  Every mutant replays with a fresh `init/2`, so fresh `AshQuint.Names`, in
  the caller's process and sandbox, one after another. The adapter's
  `project/1` must therefore be scoped to its own trace (see
  `AshQuint.Adapter`). A mutant that raises counts as detected.

  `use AshQuint.Case, sensitivity: true` runs the check as a test.
  """

  alias AshQuint.{Replay, Trace}

  @type mutant ::
          {:perturb, trace :: String.t(), index :: pos_integer(), key :: term()}
          | {:drop, trace :: String.t(), index :: pos_integer(), action :: String.t()}

  @type target :: {:key, term()} | {:call, String.t()}

  @type result :: %{survived: [mutant()], untested: [target()], tested: [target()]}

  @doc """
  Replays `traces` and their mutants through `adapter`.

  `opts` are `AshQuint.Replay.run/3`'s, without `:mutate`. Returns the
  mutants that survived, the keys and calls that are untested, and the
  ones that had a mutant (`tested`). A mutant's trace is named
  `"<source> <name>"`. Targets are listed keys first, then calls, each
  sorted; survivors in the same order.

  Raises `ArgumentError` when a clean replay fails.
  """
  @spec check(module(), [Trace.t()], [Replay.option()]) :: result()
  def check(adapter, traces, opts \\ []) do
    opts = Keyword.delete(opts, :mutate)
    reports = Enum.map(traces, &{&1, clean!(adapter, &1, opts)})

    perturbs = first_changes(reports, :key)
    drops = first_changes(reports, :call)

    mutants =
      for {key, {trace, index}} <- Enum.sort(perturbs.found),
          do: {{:key, key}, {trace, {:perturb, Trace.label(trace), index, key}}}

    mutants =
      mutants ++
        for {action, {trace, index}} <- Enum.sort(drops.found),
            do: {{:call, action}, {trace, {:drop, Trace.label(trace), index, action}}}

    survived =
      for {_target, {trace, mutant}} <- mutants,
          not detected?(adapter, trace, mutant, opts),
          do: mutant

    untested =
      Enum.map(Enum.sort(perturbs.unchanged), &{:key, &1}) ++
        Enum.map(Enum.sort(drops.unchanged), &{:call, &1})

    %{survived: survived, untested: untested, tested: Enum.map(mutants, &elem(&1, 0))}
  end

  @doc """
  Describes a result's survivors and untested targets, one line each.
  """
  @spec format(result()) :: String.t()
  def format(%{survived: survived, untested: untested}) do
    Enum.map_join(survived ++ untested, "\n", &line/1)
  end

  defp line({:perturb, trace, index, key}),
    do: "perturbed #{inspect(key)} at #{trace} step #{index} was not detected"

  defp line({:drop, trace, index, action}),
    do: "dropped #{action} at #{trace} step #{index} was not detected"

  defp line({:key, key}), do: "key #{inspect(key)} never changes in any trace"
  defp line({:call, action}), do: "no step of #{action} changes the state"

  defp clean!(adapter, trace, opts) do
    case Replay.run(adapter, trace, opts) do
      {:ok, report} ->
        report

      {:error, failure} ->
        raise ArgumentError, "sensitivity needs passing replays; #{failure.message}"
    end
  end

  # For each key (or action with an :ok step), the first synced step whose
  # expected value differs from the previous synced step's. `found` maps a
  # target to `{trace, index}`; `unchanged` lists the targets without one.
  defp first_changes(reports, kind) do
    candidates =
      for {trace, report} <- reports,
          {entry, previous} <- with_previous(report),
          target <- targets(kind, entry, previous),
          do: {target, changed?(kind, target, entry, previous), {trace, entry.index}}

    found =
      Enum.reduce(candidates, %{}, fn
        {target, true, at}, found -> Map.put_new(found, target, at)
        _candidate, found -> found
      end)

    all = candidates |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    %{found: found, unchanged: Enum.reject(all, &Map.has_key?(found, &1))}
  end

  defp with_previous(%{synced: synced, initial_expected: initial}) do
    Enum.zip(synced, [initial | Enum.map(synced, & &1.expected)])
  end

  defp targets(:key, entry, _previous), do: Map.keys(entry.expected)
  defp targets(:call, %{kind: :ok, action: action}, _previous), do: [action]
  defp targets(:call, _entry, _previous), do: []

  defp changed?(:key, key, entry, previous),
    do: Map.fetch(entry.expected, key) != Map.fetch(previous, key)

  defp changed?(:call, _action, entry, previous), do: entry.expected != previous

  defp detected?(adapter, trace, mutant, opts) do
    case Replay.run(adapter, trace, [mutate: mutation(mutant)] ++ opts) do
      {:ok, _report} -> false
      {:error, failure} -> caught?(mutant, failure)
    end
  rescue
    _error -> true
  end

  defp mutation({:perturb, _trace, index, key}), do: {:perturb, index, key}
  defp mutation({:drop, _trace, index, _action}), do: {:drop, index}

  defp caught?({:perturb, _trace, index, key}, failure),
    do: failure.index == index and String.contains?(failure.message, inspect(key))

  defp caught?({:drop, _trace, index, _action}, failure), do: failure.index >= index
end
