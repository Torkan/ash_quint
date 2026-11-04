defmodule AshQuint.Replay do
  @moduledoc """
  Replays one trace through an `AshQuint.Adapter`.

  The initial state (index 0) isn't replayed: its action must be
  `init_action`, `init/2` builds the `ctx`, and `project/1` and
  `expected/2` are called once on it, to record the initial expected
  values (nothing is compared). For every later state, in order:

    1. the state becomes an `AshQuint.Step`;
    2. `adapter.step(ctx, step)` runs it, in the test process, under a
       watchdog when ops are in flight;
    3. what it returned is handled:
       * `{:ok, result, ctx}`: its `outcome/1` must match the step's result
         when the trace has one (`{:failed, msg}` always fails); it closes a
         pending step;
       * `{:skip, ctx}`: no outcome is asserted;
       * `{:pending, ctx}` opens a pending step, the sequential form: a
         second one, or a `{:skip, …}` while one is open, is refused;
       * `{:start, op, call, ctx}` runs `call` in an op task, which stops at
         `AshQuint.Gate` gates; `{:advance, op, ctx}` releases it to its
         next gate; `{:complete, op, ctx}` releases it through every gate,
         waits for its result and checks its `outcome/1` like `{:ok, …}`;
       * the model and the adapter must agree: a step whose result is
         `Pending` must return `:start`, `:advance` or `:pending`, and a
         step with another result mustn't return `:start` or `:advance`;
    4. the ops in flight settle: each reaches a gate or finishes (or counts
       as blocked, with `may_block: true`), within `:settle_timeout`;
    5. except after `{:pending, …}`, `project/1` must equal the expected
       values on its keys, and every invariant must hold; all of a step's
       failures are reported together;
    6. a trace that ends with a step pending fails; one that ends with ops
       in flight passes, and the ops are cancelled unchecked.

  See the README's "Concurrent calls" for the op tasks, gates and
  timeouts. A failure with ops in flight ends with an `in flight:` line and
  lists them in its `:in_flight` field.

  Once `init/2` has returned, the replay ends with the adapter's
  `finish/2`, when it defines one, called exactly once with the latest `ctx`
  and the result: `:ok` after the last step's checks, `{:error, failure}` at
  the first failing step. Every op task has stopped by then, on every path.
  When an adapter callback raises (or throws or
  exits), `finish/2` gets the `ctx` that callback was given and
  `{:error, failure}` describing the exception, and then the exception
  propagates. An `{:error, message}` from `finish/2` fails a passing replay at
  the last step; on a failing replay its return value is ignored.

  Every failure message starts with
  `<model> <source> <name>, step <index> (<action>), seed <seed>: `.
  """

  alias AshQuint.{Adapter, Gate, Step, Trace}
  alias AshQuint.Replay.Ops

  # {:pending, ctx} is the sequential form: one at a time, and nothing but
  # the {:ok, …} that completes it while it is open.
  @use_start "use {:start, op, call, ctx} and {:complete, op, ctx} for calls that stay in flight"
  @second_pending "interleaved trace: two {:pending, …} steps overlap; #{@use_start}"
  @skip_pending "interleaved trace: {:skip, …} while a {:pending, …} step is open; #{@use_start}"
  @ends_pending "interleaved trace: the trace ends with this {:pending, …} step open; " <>
                  @use_start

  @type mutation ::
          nil
          | {:perturb, non_neg_integer(), term()}
          | {:drop, non_neg_integer()}
          | {:serialize, non_neg_integer()}

  @type option ::
          {:model, atom()}
          | {:adapter_opts, keyword()}
          | {:action_path, [String.t(), ...]}
          | {:result_path, [String.t(), ...]}
          | {:pending_result, String.t()}
          | {:op_field, String.t()}
          | {:init_action, String.t()}
          | {:mutate, mutation()}
          | {:settle_timeout, non_neg_integer()}
          | {:step_timeout, non_neg_integer()}
          | {:complete_timeout, non_neg_integer()}
          | {:gate_timeout, non_neg_integer()}

  @type synced :: %{
          index: pos_integer(),
          action: String.t(),
          kind: :ok | :skip | :start | :advance | :complete,
          op: String.t() | nil,
          expected: map()
        }

  @type report :: %{synced: [synced()], initial_expected: map()}

  @type in_flight :: %{
          op: String.t(),
          started_at: pos_integer(),
          at_gate: AshQuint.Gate.name() | nil
        }

  @type failure :: %{
          required(:index) => non_neg_integer(),
          required(:action) => String.t(),
          required(:message) => String.t(),
          optional(:in_flight) => [in_flight()]
        }

  @doc """
  Replays `trace` through `adapter`.

  Returns `{:ok, report}`, where `report.synced` lists the steps that
  synced (every step but `{:pending, …}` ones) with their kind (`:ok`,
  `:skip`, `:start`, `:advance` or `:complete`), op (`nil` for `:ok` and
  `:skip`) and expected values, and
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
      `{:skip, ctx}` without calling `step/2`, closing any pending step;
      when that step's result is `Pending` (a start or an advance), its op
      is dropped: the op's later `{:advance, …}` and `{:complete, …}` sync
      as skips, so a dropped start never runs and a dropped completion
      leaves its op at its gate until it is cancelled at the end;
      `{:serialize, index}` runs the op started at step `index` through
      every gate to its result at its start (no early-finish check), and
      holds the result until the op's completion step. Default `nil`.
    * `:settle_timeout` — how long an op in flight may take to reach a gate
      or finish after a step (ms). Default `500`.
    * `:step_timeout` — how long a `step/2` call may take while ops are in
      flight before the watchdog frees the gated ops and fails the step
      (ms). Default `2_000`.
    * `:complete_timeout` — how long a completed op may take to return
      (ms). Default `5_000`.
    * `:gate_timeout` — how long an op is held at a gate before the gate
      returns anyway and the replay fails (ms). Default `5_000`.
  """
  @spec run(module(), Trace.t(), [option()]) :: {:ok, report()} | {:error, failure()}
  def run(adapter, %Trace{} = trace, opts \\ []) do
    run = %{
      adapter: adapter,
      trace: trace,
      model: Keyword.get(opts, :model),
      step_opts: Keyword.take(opts, [:action_path, :result_path, :pending_result, :op_field]),
      init_action: Keyword.get(opts, :init_action, "Init"),
      mutate: Keyword.get(opts, :mutate),
      ref: make_ref(),
      timeouts: %{
        settle: Keyword.get(opts, :settle_timeout, 500),
        step: Keyword.get(opts, :step_timeout, 2_000),
        complete: Keyword.get(opts, :complete_timeout, 5_000),
        gate: Keyword.get(opts, :gate_timeout, 5_000)
      }
    }

    previous = Gate.put_current_replay(run.ref)

    try do
      with {:ok, ctx, step0} <- start(run, Keyword.get(opts, :adapter_opts, [])) do
        {result, st} = replay_from(run, ctx, step0)
        finish(run, st, result)
      end
    after
      # Every path has cancelled already; this is for exceptions.
      Gate.cancel_all(run.ref, %{})
      Gate.put_current_replay(previous)
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

  # Returns the result with the replay's state: the latest ctx and the last
  # step (for a failure from finish/2 on a passing replay).
  defp replay_from(run, ctx, step0) do
    st = %{ctx: ctx, pending: nil, ops: %{}, dropped: %{}, synced: [], last: step0}

    with {:ok, initial_expected} <- initial_expected(run, st, step0),
         {:ok, st} <- replay(run, st) do
      {{:ok, %{synced: Enum.reverse(st.synced), initial_expected: initial_expected}}, st}
    else
      {:error, failure, st} -> {{:error, failure}, st}
    end
  end

  # Every op task is dead before finish/2 runs.
  defp finish(run, %{ctx: ctx, last: last} = st, result) do
    Gate.cancel_all(run.ref, st.ops)

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

  defp initial_expected(run, %{ctx: ctx} = st, step0) do
    with {:ok, projected} <-
           initial(run, st, step0, "project/1", fn -> run.adapter.project(ctx) end),
         {:ok, expected} <-
           initial(run, st, step0, "expected/2", fn ->
             Adapter.expected(run.adapter, ctx, step0, projected)
           end) do
      {:ok, Map.take(expected, Map.keys(projected))}
    end
  end

  # The initial state's project/1 and expected/2 calls have no step/2 call
  # around them, so an exception there is reported at step 0 instead of
  # propagating without the trace and seed.
  defp initial(run, st, step0, callback, fun) do
    guard(run, st.ctx, step0, callback, fn ->
      try do
        {:ok, fun.()}
      rescue
        error -> halt_error(run, step0, st, [raised(callback, :error, error, __STACKTRACE__)])
      end
    end)
  end

  defp replay(run, st) do
    run.trace.states
    |> Enum.with_index()
    |> Enum.drop(1)
    |> Enum.reduce_while({:ok, st}, fn {state, index}, {:ok, st} ->
      case Step.from_state(state, index, run.step_opts) do
        {:ok, step} -> step(run, step, st)
        {:error, reason} -> halt(run, index, "?", st, [reason])
      end
    end)
    |> case do
      {:ok, %{pending: nil} = st} -> {:ok, st}
      {:ok, %{pending: %Step{} = open} = st} -> halt_error(run, open, st, [@ends_pending])
      {:error, _failure, _st} = error -> error
    end
  end

  defp step(run, step, st) do
    # A call that blocks on what a gated op holds is caught by a watchdog.
    called =
      guard(run, st.ctx, step, "step/2", fn ->
        watchdog = Ops.watch(st.ops, run.timeouts)

        try do
          call(run, step, st.ctx)
        catch
          kind, reason ->
            Ops.unwatch(watchdog)
            :erlang.raise(kind, reason, __STACKTRACE__)
        else
          called -> {called, Ops.unwatch(watchdog)}
        end
      end)

    case called do
      {called, :ok} ->
        called(run, step, st, called)

      {called, {:fired, held}} ->
        {ops, lines} = Ops.fired(run.ref, timeouts(run, st, step), st.ops, step, held)
        halt(run, step, %{st | ctx: returned_ctx(called, st.ctx), ops: ops}, lines)
    end
  end

  defp returned_ctx({:returned, returned}, ctx) when is_tuple(returned) do
    case returned do
      {:ok, _result, ctx} -> ctx
      {tag, ctx} when tag in [:pending, :skip] -> ctx
      {:start, _op, _call, ctx} -> ctx
      {:start, _op, _call, ctx, _opts} -> ctx
      {:advance, _op, ctx} -> ctx
      {:advance, _op, ctx, _opts} -> ctx
      {:complete, _op, ctx} -> ctx
      _other -> ctx
    end
  end

  defp returned_ctx(_called, ctx), do: ctx

  defp called(run, step, st, called) do
    case called do
      :no_clause ->
        halt(run, step, st, [
          "adapter #{inspect(run.adapter)} has no step/2 clause for `#{step.action_taken}`"
        ])

      :dropped ->
        sync_step(run, step, :skip, [], %{st | pending: nil, dropped: dropped(st.dropped, step)})

      {:returned, returned} ->
        handle(run, step, st, returned)
    end
  end

  defp handle(run, step, st, returned) do
    case returned do
      {:pending, ctx} when st.pending != nil ->
        halt(run, step, %{st | ctx: ctx}, [@second_pending])

      {:pending, ctx} ->
        {:cont, {:ok, %{st | ctx: ctx, pending: step, last: step}}}

      {:skip, ctx} when st.pending != nil ->
        halt(run, step, %{st | ctx: ctx}, [@skip_pending])

      {:ok, _result, ctx} when step.result == :pending ->
        halt(run, step, %{st | ctx: ctx}, [in_flight(run, step, "{:ok, …}")])

      {:skip, ctx} when step.result == :pending ->
        halt(run, step, %{st | ctx: ctx}, [in_flight(run, step, "{:skip, …}")])

      {:skip, ctx} ->
        sync_step(run, step, :skip, [], %{st | ctx: ctx})

      {:ok, result, ctx} ->
        errors =
          guard(run, ctx, step, "outcome/1", fn -> outcome_errors(run.adapter, step, result) end)

        sync_step(run, step, :ok, errors, %{st | ctx: ctx, pending: nil})

      returned ->
        handle_op(run, step, st, returned)
    end
  end

  # A dropped Pending step is a start (or an advance) that never happened:
  # the op's later advances and its completion are skips, so a dropped
  # start leaves the state as if the op never ran, and a dropped advance
  # leaves the op at its gate until it is cancelled at the end.
  defp dropped(dropped, %Step{result: :pending, op: op}) when is_binary(op),
    do: Map.put(dropped, op, true)

  defp dropped(dropped, _step), do: dropped

  # The returns that start, advance or complete an op.
  defp handle_op(run, step, st, returned) do
    case op_return(returned) do
      {:advance, op, ctx, _opts} when is_map_key(st.dropped, op) ->
        sync_step(run, step, :skip, [], %{st | ctx: ctx})

      {:complete, op, ctx} when is_map_key(st.dropped, op) ->
        sync_step(run, step, :skip, [], %{st | ctx: ctx, dropped: Map.delete(st.dropped, op)})

      {:start, op, call, ctx, opts} ->
        start_op(run, step, %{st | ctx: ctx}, op, call, opts)

      {:advance, op, ctx, opts} ->
        advance_op(run, step, %{st | ctx: ctx}, op, opts)

      {:complete, op, ctx} ->
        complete_op(run, step, %{st | ctx: ctx}, op)

      :error ->
        halt(run, step, st, [
          "step/2 returned #{inspect(returned)}; " <>
            "expected {:ok, result, ctx}, {:pending, ctx}, {:skip, ctx}, " <>
            "{:start, op, call, ctx}, {:advance, op, ctx} or {:complete, op, ctx}"
        ])
    end
  end

  defp op_return({:start, op, call, ctx}), do: op_return({:start, op, call, ctx, []})

  defp op_return({:start, op, call, _ctx, opts} = start)
       when is_binary(op) and is_function(call, 0) and is_list(opts),
       do: start

  defp op_return({:advance, op, ctx}), do: op_return({:advance, op, ctx, []})

  defp op_return({:advance, op, _ctx, opts} = advance) when is_binary(op) and is_list(opts),
    do: advance

  defp op_return({:complete, op, _ctx} = complete) when is_binary(op), do: complete
  defp op_return(_returned), do: :error

  # A step that made no op call still handles what the ops did meanwhile
  # (a gate timeout, a raise).
  defp sync_step(run, step, kind, errors, %{ops: ops} = st) when ops == %{},
    do: sync(run, step, kind, errors, st)

  defp sync_step(run, step, kind, errors, st) do
    {ops, lines} = Ops.settle(run.ref, timeouts(run, st, step), st.ops, step)
    settled(run, step, kind, errors, %{st | ops: ops}, nil, lines)
  end

  defp start_op(run, step, st, op, call, opts) do
    cond do
      step.result not in [:pending, nil] ->
        halt(run, step, st, [completes_here(step, "{:start, #{inspect(op)}, …}")])

      Map.has_key?(st.ops, op) ->
        halt(run, step, st, [
          "op #{inspect(op)} was started at step #{st.ops[op].started_at} and is started again"
        ])

      not valid_opts?(opts, [:early, :may_block, :at]) ->
        halt(run, step, st, [
          "step/2 returned {:start, #{inspect(op)}, …} with options #{inspect(opts)}; " <>
            "expected early: :ok, may_block: boolean() and at: a gate name"
        ])

      true ->
        # A serialized op runs through every gate to its result here.
        free = run.mutate == {:serialize, step.index}

        {ops, lines} =
          Ops.start(run.ref, timeouts(run, st, step), st.ops, step, op, call, opts, free)

        early = if free, do: [], else: early(run, step, op, ops[op], opts)
        lines = lines ++ early ++ at(op, ops[op], opts)
        settled(run, step, :start, [], %{st | ops: ops}, op, lines)
    end
  end

  defp advance_op(run, step, st, op, opts) do
    cond do
      step.result not in [:pending, nil] ->
        halt(run, step, st, [completes_here(step, "{:advance, #{inspect(op)}, …}")])

      not Map.has_key?(st.ops, op) ->
        halt(run, step, st, [not_in_flight("advance", op, st.ops)])

      not valid_opts?(opts, [:may_block, :at]) ->
        halt(run, step, st, [
          "step/2 returned {:advance, #{inspect(op)}, …} with options #{inspect(opts)}; " <>
            "expected may_block: boolean() and at: a gate name"
        ])

      true ->
        before = st.ops[op]
        {ops, lines} = Ops.advance(run.ref, timeouts(run, st, step), st.ops, step, op, opts)

        early =
          if match?({:finished, _}, before.status),
            do: [],
            else: early(run, step, op, ops[op], before.opts)

        lines = lines ++ early ++ at(op, ops[op], opts)
        settled(run, step, :advance, [], %{st | ops: ops}, op, lines)
    end
  end

  # The timeouts for Ops, with the adapter's blocked?/2 (when it has one)
  # as a function of an op and its entry. A raise in it is the adapter's.
  defp timeouts(run, st, step) do
    if Adapter.exports?(run.adapter, :blocked?, 2),
      do: Map.put(run.timeouts, :blocked, &blocked?(run, st, step, &1, &2)),
      else: run.timeouts
  end

  defp blocked?(run, st, step, op, entry) do
    info = %{op: op, pid: entry.pid, started_at: entry.started_at, info: Gate.info(entry.pid)}
    guard(run, st.ctx, step, "blocked?/2", fn -> run.adapter.blocked?(st.ctx, info) end) == true
  end

  defp valid_opts?(opts, keys) do
    Enum.all?(opts, fn
      {:early, :ok} -> :early in keys
      {:may_block, may_block} when is_boolean(may_block) -> :may_block in keys
      {:at, name} when is_atom(name) or is_tuple(name) -> :at in keys
      _other -> false
    end)
  end

  # With `at: name`, the op must be held at that gate.
  defp at(op, %{status: {:gate, name, _pid, _reply}}, opts) do
    case Keyword.fetch(opts, :at) do
      {:ok, ^name} ->
        []

      {:ok, expected} ->
        [
          "op #{inspect(op)} reached gate #{inspect(name)}; " <>
            "the adapter expected #{inspect(expected)}"
        ]

      :error ->
        []
    end
  end

  defp at(_op, _entry, _opts), do: []

  # Syncs a step whose ops have settled. Problems with the ops (`op_lines`)
  # halt before projecting: an op may still be between gates.
  defp settled(run, step, kind, errors, st, op, op_lines) do
    if op_lines == [],
      do: sync(run, step, kind, errors, st, op),
      else: halt(run, step, st, errors ++ op_lines)
  end

  defp complete_op(run, step, st, op) do
    cond do
      step.result == :pending ->
        halt(run, step, st, [in_flight(run, step, "{:complete, #{inspect(op)}, …}")])

      not Map.has_key?(st.ops, op) ->
        halt(run, step, st, [not_in_flight("complete", op, st.ops)])

      true ->
        complete_in_flight(run, step, st, op)
    end
  end

  defp complete_in_flight(run, step, st, op) do
    entry = st.ops[op]
    {ops, result, lines} = Ops.complete(run.ref, timeouts(run, st, step), st.ops, step, op)
    st = %{st | ops: ops}
    errors = op_outcome_errors(run, step, st, op, entry, result)
    settled(run, step, :complete, errors, st, op, lines)
  end

  # nil: the op didn't return in time, which Ops.complete/5 reports.
  defp op_outcome_errors(_run, _step, _st, _op, _entry, nil), do: []

  defp op_outcome_errors(_run, _step, _st, op, _entry, {:raised, _, _, _} = result),
    do: [Ops.raised_line(op, result)]

  defp op_outcome_errors(run, step, st, op, entry, {:returned, value}) do
    prefix = "op #{inspect(op)} (started at step #{entry.started_at}): "

    guard(run, st.ctx, step, "outcome/1", fn ->
      Enum.map(outcome_errors(run.adapter, step, value), &(prefix <> &1))
    end)
  end

  # The model and the adapter must agree on which steps keep a call in
  # flight (§4.3 of the design): a Pending step starts or advances an op, a
  # step with another result doesn't. Without a result, anything goes.
  defp in_flight(run, step, returned) do
    pending = Keyword.get(run.step_opts, :pending_result, "Pending")

    "the model keeps #{step.action_taken} in flight (lastResult #{pending}), " <>
      "but step/2 returned #{returned}"
  end

  # An op that returns at its start step, before any gate, didn't overlap
  # anything: fail unless the adapter allows it (`early: :ok`). An op that
  # raised is reported as such.
  defp early(run, step, op, %{status: {:finished, {:returned, _value}}}, opts) do
    if Keyword.get(opts, :early) == :ok do
      []
    else
      until =
        case completion(run, step, op) do
          nil -> "a later step"
          index -> "step #{index}"
        end

      [
        "op #{inspect(op)} finished before reaching a gate; " <>
          "the model keeps it in flight until #{until}"
      ]
    end
  end

  defp early(_run, _step, _op, _entry, _opts), do: []

  # The index of the first later step with `op` that isn't Pending.
  defp completion(run, step, op) do
    run.trace.states
    |> Enum.with_index()
    |> Enum.drop(step.index + 1)
    |> Enum.find_value(fn {state, index} ->
      case Step.from_state(state, index, run.step_opts) do
        {:ok, %Step{op: ^op, result: result}} when result != :pending -> index
        _other -> nil
      end
    end)
  end

  defp completes_here(step, returned),
    do: "the model completes #{step.action_taken} here, but step/2 returned #{returned}"

  defp not_in_flight(verb, op, ops) do
    in_flight =
      if ops == %{},
        do: "no op is in flight",
        else: "in flight: " <> Enum.map_join(Enum.sort(Map.keys(ops)), ", ", &inspect/1)

    "#{verb} of op #{inspect(op)}, which isn't in flight; " <> in_flight
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

  defp sync(run, step, kind, errors, st, op \\ nil) do
    ctx = st.ctx
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

      entry = %{
        index: step.index,
        action: step.action_taken,
        kind: kind,
        op: op,
        expected: expected
      }

      {:cont, {:ok, %{st | synced: [entry | st.synced], last: step}}}
    else
      halt(run, step, st, errors)
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
      Gate.cancel_all(run.ref, %{})

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

  defp halt(run, step, st, lines), do: {:halt, halt_error(run, step, st, lines)}

  defp halt(run, index, action, st, lines),
    do: {:halt, halt_error(run, index, action, st, lines)}

  defp halt_error(run, %Step{index: index, action_taken: action}, st, lines),
    do: halt_error(run, index, action, st, lines)

  defp halt_error(run, index, action, st, lines) do
    {:error, failure} = fail(run, index, action, lines ++ in_flight_lines(st.ops, lines))

    failure =
      if st.ops == %{}, do: failure, else: Map.put(failure, :in_flight, Ops.in_flight(st.ops))

    {:error, failure, st}
  end

  # A failure with ops in flight ends with an `in flight:` line, unless a
  # line already lists them.
  defp in_flight_lines(ops, _lines) when ops == %{}, do: []

  defp in_flight_lines(ops, lines) do
    if Enum.any?(lines, &String.contains?(&1, "in flight: ")),
      do: [],
      else: [Ops.in_flight_line(ops)]
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
