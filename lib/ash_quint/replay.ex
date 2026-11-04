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
       pending; at a step whose result is `Pending` (the model keeps the
       call in flight), `{:ok, …}` and `{:skip, …}` are refused;
    4. after `:ok` or `:skip`, `project/1` must equal the expected values on
       its keys, and every invariant must hold; all of a step's failures are
       reported together;
    5. a trace that ends with a step pending fails.

  Once `init/2` has returned, the replay ends with the adapter's
  `finish/2`, when it defines one, called exactly once with the latest `ctx`
  and the result: `:ok` after the last step's checks, `{:error, failure}` at
  the first failing step. When an adapter callback raises (or throws or
  exits), `finish/2` gets the `ctx` that callback was given and
  `{:error, failure}` describing the exception, and then the exception
  propagates. An `{:error, message}` from `finish/2` fails a passing replay at
  the last step; on a failing replay its return value is ignored.

  Every failure message starts with
  `<model> <source> <name>, step <index> (<action>), seed <seed>: `.
  """

  alias AshQuint.{Adapter, Step, Trace}

  @interleaved "interleaved trace: calls overlap here. Replaying them needs concurrent " <>
                 "replay (step/2 returning {:start, op, call, ctx} and {:complete, op, ctx}), " <>
                 "which this version of ash_quint doesn't support yet"

  @type mutation :: nil | {:perturb, non_neg_integer(), term()} | {:drop, non_neg_integer()}

  @type option ::
          {:model, atom()}
          | {:adapter_opts, keyword()}
          | {:action_path, [String.t(), ...]}
          | {:result_path, [String.t(), ...]}
          | {:pending_result, String.t()}
          | {:op_field, String.t()}
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
  `{:error, failure}` at the first failing step, or at the last step when
  the adapter's `finish/2` returns `{:error, message}` (the failure message
  then ends with `finish/2: <message>`).

  Exceptions raised by the adapter propagate, except that a
  `FunctionClauseError` raised by the adapter's own `step/2` is reported as
  a missing clause for the action, and an exception from `project/1` or
  `expected/2` on the initial state is reported at step 0. A missing clause
  in a helper that `step/2` delegates to propagates as it is. `finish/2` is
  called before an adapter exception propagates. An exception from
  `finish/2` itself propagates, except while an adapter exception is already
  propagating: that one is kept.

  ## Options

    * `:model` — the model name, for failure messages.
    * `:adapter_opts` — passed to `init/2`. Default `[]`.
    * `:action_path`, `:result_path` — where the action and result are.
      Default `["lastAction"]` and `["lastResult"]`.
    * `:pending_result`, `:op_field` — the result variant of a step that
      keeps its call in flight, and the action's operation id field (see
      `AshQuint.Step`). Default `"Pending"` and `"op"`.
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
      step_opts: Keyword.take(opts, [:action_path, :result_path, :pending_result, :op_field]),
      init_action: Keyword.get(opts, :init_action, "Init"),
      mutate: Keyword.get(opts, :mutate)
    }

    with {:ok, ctx, step0} <- start(run, Keyword.get(opts, :adapter_opts, [])) do
      {result, ctx, last} = replay_from(run, ctx, step0)
      finish(run, ctx, last, result)
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
        {:ok, ctx, step0}

      {:ok, %Step{action_taken: action}} ->
        fail(run, 0, action, ["initial state's action is #{action}, expected #{run.init_action}"])

      {:error, reason} ->
        fail(run, 0, "?", [reason])
    end
  end

  # Returns the result with the latest ctx and the last step (for a failure
  # from finish/2 on a passing replay).
  defp replay_from(run, ctx, step0) do
    with {:ok, initial_expected} <- initial_expected(run, ctx, step0),
         {:ok, synced, ctx, last} <- replay(run, ctx, step0) do
      {{:ok, %{synced: synced, initial_expected: initial_expected}}, ctx, last}
    else
      {:error, failure, ctx} -> {{:error, failure}, ctx, nil}
    end
  end

  defp finish(run, ctx, last, result) do
    case {result, Adapter.finish(run.adapter, ctx, finished(result))} do
      {{:error, _failure}, _ignored} ->
        result

      {{:ok, _report}, :ok} ->
        result

      {{:ok, _report}, {:error, message}} when is_binary(message) ->
        fail(run, last, ["finish/2: #{message}"])

      {{:ok, _report}, other} ->
        fail(run, last, [
          "finish/2 returned #{inspect(other)}; expected :ok or {:error, message}"
        ])
    end
  end

  defp finished({:ok, _report}), do: :ok
  defp finished({:error, _failure} = error), do: error

  defp initial_expected(run, ctx, step0) do
    with {:ok, projected} <-
           initial(run, ctx, step0, "project/1", fn -> run.adapter.project(ctx) end),
         {:ok, expected} <-
           initial(run, ctx, step0, "expected/2", fn ->
             Adapter.expected(run.adapter, ctx, step0, projected)
           end) do
      {:ok, Map.take(expected, Map.keys(projected))}
    end
  end

  # The initial state's project/1 and expected/2 calls have no step/2 call
  # around them, so an exception there is reported at step 0 instead of
  # propagating without the trace and seed.
  defp initial(run, ctx, step0, callback, fun) do
    guard(run, ctx, step0, callback, fn ->
      try do
        {:ok, fun.()}
      rescue
        error -> halt_error(run, step0, ctx, [raised(callback, :error, error, __STACKTRACE__)])
      end
    end)
  end

  defp replay(run, ctx, step0) do
    run.trace.states
    |> Enum.with_index()
    |> Enum.drop(1)
    |> Enum.reduce_while({:ok, ctx, nil, [], step0}, fn {state, index},
                                                        {:ok, ctx, pending, synced, _last} ->
      case Step.from_state(state, index, run.step_opts) do
        {:ok, step} -> step(run, step, ctx, pending, synced)
        {:error, reason} -> halt(run, index, "?", ctx, [reason])
      end
    end)
    |> case do
      {:ok, ctx, nil, synced, last} -> {:ok, Enum.reverse(synced), ctx, last}
      {:ok, ctx, %Step{} = open, _synced, _last} -> halt_error(run, open, ctx, [@interleaved])
      {:error, _failure, _ctx} = error -> error
    end
  end

  defp step(run, step, ctx, pending, synced) do
    case guard(run, ctx, step, "step/2", fn -> call(run, step, ctx) end) do
      :no_clause ->
        halt(run, step, ctx, [
          "adapter #{inspect(run.adapter)} has no step/2 clause for `#{step.action_taken}`"
        ])

      :dropped ->
        sync(run, step, :skip, [], ctx, synced)

      {:returned, returned} ->
        handle(run, step, ctx, returned, pending, synced)
    end
  end

  defp handle(run, step, ctx_in, returned, pending, synced) do
    case returned do
      {:pending, ctx} when pending != nil ->
        halt(run, step, ctx, [@interleaved])

      {:pending, ctx} ->
        {:cont, {:ok, ctx, step, synced, step}}

      {:skip, ctx} when pending != nil ->
        halt(run, step, ctx, [@interleaved])

      {:ok, _result, ctx} when step.result == :pending ->
        halt(run, step, ctx, [in_flight(run, step, "{:ok, …}")])

      {:skip, ctx} when step.result == :pending ->
        halt(run, step, ctx, [in_flight(run, step, "{:skip, …}")])

      {:skip, ctx} ->
        sync(run, step, :skip, [], ctx, synced)

      {:ok, result, ctx} ->
        errors =
          guard(run, ctx, step, "outcome/1", fn -> outcome_errors(run.adapter, step, result) end)

        sync(run, step, :ok, errors, ctx, synced)

      other ->
        halt(run, step, ctx_in, [
          "step/2 returned #{inspect(other)}; " <>
            "expected {:ok, result, ctx}, {:pending, ctx} or {:skip, ctx}"
        ])
    end
  end

  defp in_flight(run, step, returned) do
    pending = Keyword.get(run.step_opts, :pending_result, "Pending")

    "the model keeps #{step.action_taken} in flight (lastResult #{pending}), " <>
      "but step/2 returned #{returned}; return {:pending, ctx} when a later step " <>
      "completes the call (concurrent replay with {:start, …} isn't supported yet)"
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
    projected = guard(run, ctx, step, "project/1", fn -> run.adapter.project(ctx) end)

    expected =
      guard(run, ctx, step, "expected/2", fn ->
        Adapter.expected(run.adapter, ctx, step, projected)
      end)

    expected = mutate(expected, run, step)

    invariant_errors =
      guard(run, ctx, step, "invariants/0", fn -> invariant_errors(run, projected, ctx) end)

    errors = errors ++ state_errors(projected, expected) ++ invariant_errors

    if errors == [] do
      # Only the projected keys were compared, so only they are reported.
      expected = Map.take(expected, Map.keys(projected))
      entry = %{index: step.index, action: step.action_taken, kind: kind, expected: expected}
      {:cont, {:ok, ctx, nil, [entry | synced], step}}
    else
      halt(run, step, ctx, errors)
    end
  end

  # Runs an adapter callback that was given ctx. If it raises, throws or
  # exits, finish/2 gets ctx and the failure before the exception propagates.
  # An exception from finish/2 there is dropped, so the adapter's own one is
  # the one reported.
  defp guard(run, ctx, step, callback, fun) do
    fun.()
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__
      result = fail(run, step, [raised(callback, kind, reason, stacktrace)])

      try do
        Adapter.finish(run.adapter, ctx, result)
      catch
        _kind, _reason -> :ok
      end

      :erlang.raise(kind, reason, stacktrace)
  end

  defp raised(callback, :error, reason, stacktrace) do
    error = Exception.normalize(:error, reason, stacktrace)
    "#{callback} raised: #{Exception.message(error)}"
  end

  defp raised(callback, :throw, value, _stacktrace), do: "#{callback} threw #{inspect(value)}"
  defp raised(callback, :exit, reason, _stacktrace), do: "#{callback} exited: #{inspect(reason)}"

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

  defp halt(run, step, ctx, lines), do: {:halt, halt_error(run, step, ctx, lines)}

  defp halt(run, index, action, ctx, lines),
    do: {:halt, halt_error(run, index, action, ctx, lines)}

  defp halt_error(run, %Step{index: index, action_taken: action}, ctx, lines),
    do: halt_error(run, index, action, ctx, lines)

  defp halt_error(run, index, action, ctx, lines) do
    {:error, failure} = fail(run, index, action, lines)
    {:error, failure, ctx}
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
