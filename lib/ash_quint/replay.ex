defmodule AshQuint.Replay do
  @moduledoc """
  Replays one trace through an `AshQuint.Adapter`.

  The initial state (index 0) isn't replayed: its action must be
  `init_action`, `init/2` builds the `ctx`, and `project/1` and
  `expected/2` are called once on it, to record the initial expected
  values (nothing is compared). For every later state, in order:

    1. the state becomes an `AshQuint.Step`;
    2. `adapter.step(ctx, step)` runs it;
    3. `{:pending, ctx}` opens a pending step (a second one is refused);
       `{:ok, result, ctx}` closes it, and its `outcome/1` must match the
       step's result when the trace has one (`{:failed, msg}` always fails);
       `{:skip, ctx}` asserts no outcome and is refused while a step is
       pending;
    4. after `:ok` or `:skip`, `project/1` must equal the expected values on
       its keys, and every invariant must hold; all of a step's failures are
       reported together;
    5. a trace that ends with a step pending fails.

  Every failure message starts with
  `<model> <source> <name>, step <index> (<action>), seed <seed>: `.
  """

  alias AshQuint.{Adapter, Step, Trace}

  @interleaved "interleaved trace: concurrent replay is out of scope for ash_quint v1"

  @type mutation :: nil | {:perturb, non_neg_integer(), term()} | {:drop, non_neg_integer()}

  @type option ::
          {:model, atom()}
          | {:adapter_opts, keyword()}
          | {:action_path, [String.t(), ...]}
          | {:result_path, [String.t(), ...]}
          | {:init_action, String.t()}
          | {:mutate, mutation()}

  @type synced :: %{
          index: pos_integer(),
          action: String.t(),
          kind: :ok | :skip,
          expected: map()
        }

  @type report :: %{synced: [synced()], initial_expected: map()}

  @type failure :: %{index: non_neg_integer(), action: String.t(), message: String.t()}

  @doc """
  Replays `trace` through `adapter`.

  Returns `{:ok, report}`, where `report.synced` lists the steps that
  returned `:ok` or `:skip` with their expected values, and
  `report.initial_expected` is the expected value of the initial state right
  after `init/2`; both keep only the projected keys. Returns
  `{:error, failure}` at the first failing step.

  Exceptions raised by the adapter propagate, except that a
  `FunctionClauseError` raised by the adapter's own `step/2` is reported as
  a missing clause for the action, and an exception from `project/1` or
  `expected/2` on the initial state is reported at step 0. A missing clause
  in a helper that `step/2` delegates to propagates as it is.

  ## Options

    * `:model` — the model name, for failure messages.
    * `:adapter_opts` — passed to `init/2`. Default `[]`.
    * `:action_path`, `:result_path` — where the action and result are.
      Default `["lastAction"]` and `["lastResult"]`.
    * `:init_action` — the initial state's action. Default `"Init"`.
    * `:mutate` — for the sensitivity check: `{:perturb, index, key}`
      replaces the expected value of `key` at step `index` with
      `{:ash_quint_mutated, key}`; `{:drop, index}` replays step `index` as
      `{:skip, ctx}` without calling `step/2`, closing any pending step. Default `nil`.
  """
  @spec run(module(), Trace.t(), [option()]) :: {:ok, report()} | {:error, failure()}
  def run(adapter, %Trace{} = trace, opts \\ []) do
    run = %{
      adapter: adapter,
      trace: trace,
      model: Keyword.get(opts, :model),
      step_opts: Keyword.take(opts, [:action_path, :result_path]),
      init_action: Keyword.get(opts, :init_action, "Init"),
      mutate: Keyword.get(opts, :mutate)
    }

    with {:ok, ctx, initial_expected} <- start(run, Keyword.get(opts, :adapter_opts, [])),
         {:ok, synced} <- replay(run, ctx) do
      {:ok, %{synced: synced, initial_expected: initial_expected}}
    end
  end

  @doc """
  Like `run/3`, but returns the report and raises `ExUnit.AssertionError`
  with the failure message when the replay fails.
  """
  @spec run!(module(), Trace.t(), [option()]) :: report()
  def run!(adapter, trace, opts \\ []) do
    case run(adapter, trace, opts) do
      {:ok, report} -> report
      {:error, failure} -> raise ExUnit.AssertionError, message: failure.message
    end
  end

  defp start(run, adapter_opts) do
    [state0 | _] = run.trace.states

    case Step.from_state(state0, 0, run.step_opts) do
      {:ok, %Step{action_taken: action} = step0} when action == run.init_action ->
        {:ok, ctx} = run.adapter.init(run.trace, adapter_opts)
        initial_expected(run, ctx, step0)

      {:ok, %Step{action_taken: action}} ->
        fail(run, 0, action, ["initial state's action is #{action}, expected #{run.init_action}"])

      {:error, reason} ->
        fail(run, 0, "?", [reason])
    end
  end

  defp initial_expected(run, ctx, step0) do
    with {:ok, projected} <-
           initial(run, step0, "project/1", fn -> run.adapter.project(ctx) end),
         {:ok, expected} <-
           initial(run, step0, "expected/2", fn ->
             Adapter.expected(run.adapter, ctx, step0, projected)
           end) do
      {:ok, ctx, Map.take(expected, Map.keys(projected))}
    end
  end

  # The initial state's project/1 and expected/2 calls have no step/2 call
  # around them, so an exception there is reported at step 0 instead of
  # propagating without the trace and seed.
  defp initial(run, step0, callback, fun) do
    {:ok, fun.()}
  rescue
    error -> fail(run, step0, ["#{callback} raised: #{Exception.message(error)}"])
  end

  defp replay(run, ctx) do
    run.trace.states
    |> Enum.with_index()
    |> Enum.drop(1)
    |> Enum.reduce_while({:ok, ctx, nil, []}, fn {state, index}, {:ok, ctx, pending, synced} ->
      case Step.from_state(state, index, run.step_opts) do
        {:ok, step} -> step(run, step, ctx, pending, synced)
        {:error, reason} -> {:halt, fail(run, index, "?", [reason])}
      end
    end)
    |> case do
      {:ok, _ctx, nil, synced} -> {:ok, Enum.reverse(synced)}
      {:ok, _ctx, %Step{} = open, _synced} -> fail(run, open, [@interleaved])
      {:error, _failure} = error -> error
    end
  end

  defp step(run, step, ctx, pending, synced) do
    case call(run, step, ctx) do
      :no_clause ->
        {:halt,
         fail(run, step, [
           "adapter #{inspect(run.adapter)} has no step/2 clause for `#{step.action_taken}`"
         ])}

      :dropped ->
        sync(run, step, :skip, [], ctx, synced)

      {:returned, returned} ->
        handle(run, step, returned, pending, synced)
    end
  end

  defp handle(run, step, returned, pending, synced) do
    case returned do
      {:pending, _ctx} when pending != nil ->
        {:halt, fail(run, step, [@interleaved])}

      {:pending, ctx} ->
        {:cont, {:ok, ctx, step, synced}}

      {:skip, _ctx} when pending != nil ->
        {:halt, fail(run, step, [@interleaved])}

      {:skip, ctx} ->
        sync(run, step, :skip, [], ctx, synced)

      {:ok, result, ctx} ->
        sync(run, step, :ok, outcome_errors(run.adapter, step, result), ctx, synced)

      other ->
        {:halt,
         fail(run, step, [
           "step/2 returned #{inspect(other)}; " <>
             "expected {:ok, result, ctx}, {:pending, ctx} or {:skip, ctx}"
         ])}
    end
  end

  # A dropped call also closes the pending step it would have completed, so
  # the mutant fails on the state, not as an interleaved trace.
  defp call(%{mutate: {:drop, index}}, %Step{index: index}, _ctx), do: :dropped

  defp call(run, step, ctx) do
    {:returned, run.adapter.step(ctx, step)}
  rescue
    error in FunctionClauseError ->
      if error.module == run.adapter and error.function == :step and error.arity == 2 do
        :no_clause
      else
        reraise error, __STACKTRACE__
      end
  end

  defp outcome_errors(adapter, step, result) do
    case Adapter.outcome(adapter, result) do
      {:failed, message} ->
        ["system call failed: #{message}"]

      outcome when step.result != nil and outcome != step.result ->
        ["outcome: expected #{inspect(step.result)}, got #{inspect(outcome)}"]

      _outcome ->
        []
    end
  end

  defp sync(run, step, kind, errors, ctx, synced) do
    projected = run.adapter.project(ctx)
    expected = run.adapter |> Adapter.expected(ctx, step, projected) |> mutate(run, step)
    errors = errors ++ state_errors(projected, expected) ++ invariant_errors(run, projected, ctx)

    if errors == [] do
      # Only the projected keys were compared, so only they are reported.
      expected = Map.take(expected, Map.keys(projected))
      entry = %{index: step.index, action: step.action_taken, kind: kind, expected: expected}
      {:cont, {:ok, ctx, nil, [entry | synced]}}
    else
      {:halt, fail(run, step, errors)}
    end
  end

  defp mutate(expected, %{mutate: {:perturb, index, key}}, %Step{index: index}),
    do: Map.put(expected, key, {:ash_quint_mutated, key})

  defp mutate(expected, _run, _step), do: expected

  defp state_errors(projected, expected) do
    for key <- projected |> Map.keys() |> Enum.sort(),
        error = key_error(key, Map.fetch!(projected, key), Map.fetch(expected, key)),
        do: error
  end

  defp key_error(key, _actual, :error), do: "expected/2 returned no value for key #{inspect(key)}"
  defp key_error(_key, actual, {:ok, actual}), do: nil

  defp key_error(key, actual, {:ok, expected}) do
    "key #{inspect(key)}:\n" <>
      "  expected: #{inspect(expected, pretty: true)}\n" <>
      "  actual:   #{inspect(actual, pretty: true)}"
  end

  defp invariant_errors(run, projected, ctx) do
    for {name, check} <- Adapter.invariants(run.adapter),
        error = invariant_error(name, check, projected, ctx),
        do: error
  end

  defp invariant_error(name, check, projected, ctx) do
    case check.(projected, ctx) do
      :ok -> nil
      {:error, message} -> "invariant #{name}: #{message}"
    end
  rescue
    error -> "invariant #{name} raised: #{Exception.message(error)}"
  end

  defp fail(run, %Step{index: index, action_taken: action}, lines),
    do: fail(run, index, action, lines)

  defp fail(run, index, action, lines) do
    trace = run.trace

    prefix =
      "#{run.model} #{Trace.label(trace)}, step #{index} (#{action}), seed #{trace.seed}: "

    {:error, %{index: index, action: action, message: prefix <> Enum.join(lines, "\n")}}
  end
end
