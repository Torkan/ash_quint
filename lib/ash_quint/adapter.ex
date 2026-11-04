defmodule AshQuint.Adapter do
  @moduledoc """
  The behaviour that connects a Quint model to the system under test.

  `AshQuint.Replay` calls `init/2` once per trace, followed by `project/1`
  and `expected/2` on the initial state (step 0, action `init_action`) to
  record its expected values; nothing is compared there. It then calls
  `step/2` for every state after the initial one. After each step that
  synced (all but `{:pending, …}`), once the ops in flight have settled, it
  compares `project/1` with
  `expected/2` on the keys `project/1` returns, and runs `invariants/0`.
  When the replay ends, pass or fail, it calls `finish/2`.

    * `init/2` builds the `ctx` for one trace. Use a map if you use
      `AshQuint.Names`.
    * `step/2` performs the step's action. Return `{:ok, result, ctx}` after
      a system call, `{:pending, ctx}` when the action only defers a call
      that a later step makes (one at a time), or `{:skip, ctx}` for a
      model-only step (state is compared, no outcome is asserted). For a
      call that stays in flight while other steps run, return
      `{:start, op, call, ctx}`: the replay runs `call` in an op task that
      stops at `AshQuint.Gate` gates; `{:advance, op, ctx}` and
      `{:complete, op, ctx}` release it at later steps (see
      `t:step_result/0` and the README's "Concurrent calls"). A step whose
      result is `Pending` (`step.result == :pending`) must return
      `:start`, `:advance` or `:pending`.
    * `project/1` returns the system's state, keyed by the model variables
      it covers.
    * `expected/2` (optional) returns the model's value for each projected
      key. A projected key it leaves out is a failure.
    * `outcome/1` (optional) classifies a system call's result as
      `:accepted`, `{:rejected, code}` or `{:failed, message}`.
    * `invariants/0` (optional) lists named checks run on every synced
      step.
    * `finish/2` (optional) runs once when the replay ends, to release what
      `ctx` holds and for checks that belong after the last step.

  ## Finishing

  `finish(ctx, result)` is called exactly once for every replay whose
  `init/2` returned, with the latest `ctx` (including one returned with
  `{:pending, ctx}`), once every op task of the replay has stopped, so it can
  release what `ctx` holds without racing them:

    * with `:ok` after the last step, once its comparison and invariants
      passed;
    * with `{:error, failure}` at the first failing step, including an
      interleaved trace and a failure at step 0;
    * with `{:error, failure}` describing the exception when an adapter
      callback raises, throws or exits, with the `ctx` that callback was
      given, before the exception propagates.

  Return `:ok`, or `{:error, message}` to fail a passing replay: the failure
  is reported at the last step, as `finish/2: <message>`. That makes
  `finish/2` the place for end-of-trace checks (a witness reached on the
  real system). On a failing replay the original failure is kept and the
  return value is ignored.

  An exception from `finish/2` propagates, except while an adapter exception
  is already propagating: that one is kept, and `finish/2`'s is dropped.

  ## Exceptions

  An exception from `project/1` or `expected/2` on the initial state fails
  the replay at step 0. A `FunctionClauseError` from the adapter's own
  `step/2` is reported as a missing clause for the action. Any other
  exception propagates as it is, including a missing clause in a helper
  that `step/2` delegates to.

  ## Defaults

  `use AshQuint.Adapter` declares the behaviour and defines an overridable
  `outcome/1`: `AshQuint.Ash.outcome/1` when Ash is loaded where the adapter
  is compiled, else `default_outcome/1`.

  `AshQuint.Replay` supplies a default for each optional callback the
  adapter doesn't define, with or without `use`:

    * `expected/2`: the model state on the projected keys,
      `Map.take(step.state, Map.keys(projected))`, for models whose values
      are already real;
    * `outcome/1`: as above, decided at run time (see `outcome/2`);
    * `invariants/0`: `[]`;
    * `finish/2`: none; nothing is called when the replay ends.

  ## Scoping the projection

  `project/1` must report only the state of the trace being replayed: the
  sensitivity check replays every trace and mutant in one sandbox, one after
  another. Scope it to something `init/2` creates (a tenant), or to the
  records named in the trace's `AshQuint.Names`.

  ## Invariants

  An invariant sees only the projected state and `ctx`. A transition
  invariant, one that compares a step with the one before, keeps what it
  needs (the rows before the call, a counter) in `ctx`.
  """

  alias AshQuint.Step

  # AshQuint.Ash is compiled only when Ash is loaded; outcome/2 checks for it.
  @compile {:no_warn_undefined, AshQuint.Ash}

  @type ctx :: term()

  @type outcome :: :accepted | {:rejected, String.t()} | {:failed, String.t()}

  @type invariant :: {atom(), (projected :: map(), ctx() -> :ok | {:error, String.t()})}

  @doc "Builds the `ctx` for one trace."
  @callback init(AshQuint.Trace.t(), opts :: keyword()) :: {:ok, ctx()}

  @typedoc "An operation id: names a call that stays in flight across steps."
  @type op :: String.t()

  @typedoc """
  Options of `{:start, op, call, ctx, opts}`:

    * `early: :ok` — the call may finish before it reaches a gate (else
      that is a failure; its result is held until its completion step);
    * `may_block: true` — an op that neither reaches a gate nor finishes
      within the settle timeout counts as blocked instead of failing;
    * `at: name` — the first gate the op must reach.
  """
  @type start_opts :: [early: :ok, may_block: boolean(), at: AshQuint.Gate.name()]

  @typedoc """
  Options of `{:advance, op, ctx, opts}`: `at: name`, the gate the op must
  reach next, and `may_block: true`, as for `t:start_opts/0`.
  """
  @type advance_opts :: [at: AshQuint.Gate.name(), may_block: boolean()]

  @typedoc "What `step/2` returns."
  @type step_result ::
          {:ok, result :: term(), ctx()}
          | {:pending, ctx()}
          | {:skip, ctx()}
          | {:start, op(), call :: (-> term()), ctx()}
          | {:start, op(), call :: (-> term()), ctx(), start_opts()}
          | {:advance, op(), ctx()}
          | {:advance, op(), ctx(), advance_opts()}
          | {:complete, op(), ctx()}

  @doc "Performs one step of the trace."
  @callback step(ctx(), Step.t()) :: step_result()

  @doc "Returns the system state, keyed by the model variables it covers."
  @callback project(ctx()) :: map()

  @doc "Returns the model's expected value for each key of the projection."
  @callback expected(ctx(), Step.t()) :: map()

  @doc "Classifies the result of a system call."
  @callback outcome(result :: term()) :: outcome()

  @doc "Named checks run on the projection after every synced step."
  @callback invariants() :: [invariant()]

  @doc "Runs once when the replay ends, with the latest `ctx` and the result."
  @callback finish(ctx(), result :: :ok | {:error, AshQuint.Replay.failure()}) ::
              :ok | {:error, String.t()}

  @optional_callbacks expected: 2, outcome: 1, invariants: 0, finish: 2

  @doc false
  defmacro __using__(_opts) do
    # ensure_compiled/1 waits for AshQuint.Ash when it is compiled in the
    # same pass as the adapter (this repo's own test support).
    outcome =
      if match?({:module, _}, Code.ensure_compiled(AshQuint.Ash)) do
        quote do: AshQuint.Ash.outcome(result)
      else
        quote do: AshQuint.Adapter.default_outcome(result)
      end

    quote do
      @behaviour AshQuint.Adapter

      @doc false
      def outcome(result), do: unquote(outcome)

      defoverridable outcome: 1
    end
  end

  @doc """
  The outcome used without Ash: `{:ok, _}` and `:ok` are `:accepted`, and
  any other value is `{:failed, inspect(value)}`.
  """
  @spec default_outcome(term()) :: outcome()
  def default_outcome(:ok), do: :accepted
  def default_outcome({:ok, _}), do: :accepted
  def default_outcome(other), do: {:failed, inspect(other)}

  @doc """
  The expected values for a step: `adapter.expected(ctx, step)` when the
  adapter defines it, else the model state on the keys of `projected`.
  """
  @spec expected(module(), ctx(), Step.t(), map()) :: map()
  def expected(adapter, ctx, %Step{} = step, projected) do
    if exports?(adapter, :expected, 2) do
      adapter.expected(ctx, step)
    else
      Map.take(step.state, Map.keys(projected))
    end
  end

  @doc """
  Classifies `result` with `adapter.outcome(result)` when the adapter
  defines it, else with the default that `use AshQuint.Adapter` gives:
  `AshQuint.Ash.outcome/1` when Ash is loaded, else `default_outcome/1`.
  """
  @spec outcome(module(), term()) :: outcome()
  def outcome(adapter, result) do
    cond do
      exports?(adapter, :outcome, 1) -> adapter.outcome(result)
      Code.ensure_loaded?(AshQuint.Ash) -> AshQuint.Ash.outcome(result)
      true -> default_outcome(result)
    end
  end

  @doc """
  The adapter's invariants, or `[]` when it doesn't define `invariants/0`.
  """
  @spec invariants(module()) :: [invariant()]
  def invariants(adapter) do
    if exports?(adapter, :invariants, 0), do: adapter.invariants(), else: []
  end

  @doc """
  Calls `adapter.finish(ctx, result)` when the adapter defines it, else
  returns `:ok`.
  """
  @spec finish(module(), ctx(), :ok | {:error, AshQuint.Replay.failure()}) :: term()
  def finish(adapter, ctx, result) do
    if exports?(adapter, :finish, 2), do: adapter.finish(ctx, result), else: :ok
  end

  defp exports?(adapter, fun, arity) do
    Code.ensure_loaded?(adapter) and function_exported?(adapter, fun, arity)
  end
end
