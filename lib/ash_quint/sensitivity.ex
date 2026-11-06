defmodule AshQuint.Sensitivity do
  @moduledoc """
  Checks that passing replays mean something: mutants of the replay must
  fail.

  `check/3` replays every trace clean, then picks three kinds of mutant
  from the clean reports:

    * **Perturbed expectation.** For each projected key, the first synced
      step (traces in the given order, steps in order) whose expected value
      differs from the previous synced step's has that value replaced with
      `{:ash_quint_mutated, key}`. The replay must fail at that step, on
      that key. The first synced step of a trace is compared with the
      initial state's expected value right after `init/2`.
    * **Dropped call.** For each action, the first call that changed the
      expected state is replayed as a skip, with no system call. The
      replay must fail at that step or a later one. A call is a step that
      returned `{:ok, …}`, an op's completion (`{:complete, …}`) or an op's
      start (`{:start, …}`). A dropped completion leaves its op at its
      gate until the replay cancels it; a dropped start never starts its
      op, and the op's later advances and completion are skips. A start
      rarely changes the state itself, so it counts as changing it when its
      op's completion does. A rejected call, or any call that changes
      nothing, can't be detected when dropped, so it isn't chosen.
      Advances are never dropped.
    * **Serialized op.** For each action that starts ops (only concurrent
      traces have any), the first trace (in order) where one of its ops
      overlaps another op (see `overlaps/1`) is replayed with that op's
      gates ignored: it runs to completion at its start, and its result is
      held until its completion step. The replay must fail at the start or
      later. If it doesn't, the next overlapping trace is tried, until one
      detects it. A serialization that is never detected means the replay
      didn't observe the overlap: gates not wired, the race window outside
      the gates, or a projection blind to it.

  A key whose expected value never changes is reported as untested
  (`{:key, key}`), and so is an action with calls none of which changes
  the state (`{:call, action}`): the traces never show that the
  projection observes them. Actions whose steps are all skipped make no
  system call and aren't considered. A start action whose serialization is
  never detected, or whose ops never overlap another op in any trace, is
  untested too (`{:interleaving, action}`): some overlaps legitimately
  don't matter, so these can be allow-listed like keys and actions.

  A model variable that no projection covers is untested as well
  (`{:var, name}`): one of the traces' variables (`AshQuint.Trace`'s
  `vars`), other than the roots of `:action_path` and `:result_path`, that
  is never a key of a clean replay's expected values. It is tested when the
  projection has it as a key. In-flight bookkeeping (a model's set of
  pending ops, say) and model-only state are what an adapter doesn't
  project, so they are allow-listed. Keys an adapter projects under names
  that aren't model variables are not checked.

  An adapter without `project/1` projects nothing on purpose: it gets no
  perturbed expectations and no `{:var, …}` check. When it defines
  `postconditions/0` (see `AshQuint.Adapter`), each action none of whose
  calls changes the expected state gets one more dropped-call mutant, at
  its first call (an `{:ok, …}` step or an op's completion, traces in
  order) whose model result is `Accepted`: the postconditions run on the
  skipped step, so one that sees the missing effect fails the replay. A
  detected mutant tests the action (`{:call, action}`); one that survives
  is listed in `survived` and the action stays untested. Adapters without
  postconditions get only the mutants above.

  Every mutant replays with a fresh `init/2`, so fresh `AshQuint.Names`, in
  the caller's process and sandbox, one after another. The adapter's
  `project/1` must therefore be scoped to its own trace (see
  `AshQuint.Adapter`), and an adapter that holds resources should release
  them in `finish/2`, which every clean and mutant replay calls. A mutant
  that raises counts as detected.

  `use AshQuint.Case, sensitivity: true` runs the check as a test.
  """

  alias AshQuint.{Adapter, Replay, Step, Trace}

  @type mutant ::
          {:perturb, trace :: String.t(), index :: pos_integer(), key :: term()}
          | {:drop, trace :: String.t(), index :: pos_integer(), action :: String.t()}
          | {:serialize, trace :: String.t(), index :: pos_integer(), action :: String.t()}

  @type target ::
          {:key, term()} | {:call, String.t()} | {:interleaving, String.t()} | {:var, String.t()}

  @type result :: %{
          survived: [mutant()],
          untested: [target()],
          tested: [target()],
          never_overlap: [String.t()]
        }

  @doc """
  Replays `traces` and their mutants through `adapter`.

  `opts` are `AshQuint.Replay.run/3`'s, without `:mutate`. Returns the
  mutants that survived, the keys, calls, interleavings and model
  variables that are untested, and the ones that had a mutant (`tested`;
  an interleaving only when a serialization was detected, a call dropped
  for postconditions only when detected, a variable when the projection
  covers it). `never_overlap` lists the actions
  whose ops never overlap another op in any trace: their interleaving is
  untested because there is no serialization to try. A mutant's trace is
  named `"<source> <name>"`. Targets are listed keys first, then calls,
  then interleavings, then variables, each sorted; survivors in the same
  order.

  Raises `ArgumentError` when a clean replay fails.
  """
  @spec check(module(), [Trace.t()], [Replay.option()]) :: result()
  def check(adapter, traces, opts \\ []) do
    opts = Keyword.delete(opts, :mutate)
    reports = Enum.map(traces, &{&1, clean!(adapter, &1, opts)})

    perturbs = first_changes(reports, :key)
    drops = first_changes(reports, :call)
    post_drops = postcondition_drops(adapter, reports, drops.unchanged, opts)

    mutants = mutants(perturbs.found, Map.merge(drops.found, post_drops))
    {survived, mutant_tested, post_tested} = try_mutants(adapter, mutants, post_drops, opts)

    interleavings = interleavings(adapter, reports, opts)

    {projected_vars, unprojected_vars} = vars(adapter, reports, opts)

    untested =
      Enum.map(Enum.sort(perturbs.unchanged), &{:key, &1}) ++
        Enum.map(Enum.sort(drops.unchanged -- post_tested), &{:call, &1}) ++
        for({action, false} <- interleavings, do: {:interleaving, action}) ++
        Enum.map(unprojected_vars, &{:var, &1})

    tested =
      mutant_tested ++
        for({action, true} <- interleavings, do: {:interleaving, action}) ++
        Enum.map(projected_vars, &{:var, &1})

    never_overlap =
      for {action, false} <- interleavings,
          not Enum.any?(reports, &overlapping_start(&1, action)),
          do: action

    %{survived: survived, untested: untested, tested: tested, never_overlap: never_overlap}
  end

  # Keys first, then calls, each sorted: {target, {trace, mutant}}.
  defp mutants(perturbs, drops) do
    for(
      {key, {trace, index}} <- Enum.sort(perturbs),
      do: {{:key, key}, {trace, {:perturb, Trace.label(trace), index, key}}}
    ) ++
      for {action, {trace, index}} <- Enum.sort(drops),
          do: {{:call, action}, {trace, {:drop, Trace.label(trace), index, action}}}
  end

  # Replays every mutant. Returns the survivors, the targets they test (a
  # postcondition mutant only when detected) and the actions whose
  # postcondition mutant was detected.
  defp try_mutants(adapter, mutants, post_drops, opts) do
    tried =
      for {target, {trace, mutant}} <- mutants,
          do: {target, mutant, detected?(adapter, trace, mutant, opts)}

    post? = fn target -> match?({:call, action} when is_map_key(post_drops, action), target) end

    {for({_target, mutant, false} <- tried, do: mutant),
     for({target, _mutant, detected} <- tried, detected or not post?.(target), do: target),
     for({{:call, action} = target, _mutant, true} <- tried, post?.(target), do: action)}
  end

  # With postconditions, each of `actions` (calls that never change the
  # expected state) is dropped at its first synced {:ok, …} or completion
  # whose model result is Accepted, traces in order: `%{action => {trace,
  # index}}`. Without postconditions, none is.
  defp postcondition_drops(adapter, reports, actions, opts) do
    if Adapter.postconditions(adapter) == [] do
      %{}
    else
      step_opts = Step.options(opts)

      found =
        for {trace, report} <- reports,
            %{kind: kind, action: action, index: index} <- report.synced,
            kind in [:ok, :complete],
            action in actions,
            accepted?(trace, index, step_opts),
            do: {action, {trace, index}}

      Enum.reduce(found, %{}, fn {action, at}, acc -> Map.put_new(acc, action, at) end)
    end
  end

  defp accepted?(trace, index, step_opts) do
    match?(
      {:ok, %Step{result: :accepted}},
      Step.from_state(Enum.at(trace.states, index), index, step_opts)
    )
  end

  # The traces' model variables (without the action and result roots),
  # sorted and split by whether some clean report's expected values have
  # them as a key, that is, whether the projection covers them. An adapter
  # without project/1 projects nothing on purpose: no variable is checked.
  defp vars(adapter, reports, opts) do
    if Adapter.exports?(adapter, :project, 1),
      do: projected_vars(reports, opts),
      else: {[], []}
  end

  defp projected_vars(reports, opts) do
    model_vars =
      for({trace, _report} <- reports, var <- trace.vars, uniq: true, do: var) --
        Step.roots(opts)

    projected =
      for {_trace, report} <- reports,
          expected <- [report.initial_expected | Enum.map(report.synced, & &1.expected)],
          key <- Map.keys(expected),
          into: MapSet.new(),
          do: key

    model_vars |> Enum.sort() |> Enum.split_with(&MapSet.member?(projected, &1))
  end

  # For each action that starts ops, sorted: whether serializing one of its
  # overlapping starts fails the replay. Traces are tried in order, each at
  # the action's first overlapping start, until one detects it.
  defp interleavings(adapter, reports, opts) do
    actions =
      for {_trace, report} <- reports,
          %{kind: :start, action: action} <- report.synced,
          uniq: true,
          do: action

    for action <- Enum.sort(actions),
        do: {action, Enum.any?(reports, &serialization_detected?(adapter, &1, action, opts))}
  end

  defp serialization_detected?(adapter, {trace, _report} = clean, action, opts) do
    case overlapping_start(clean, action) do
      nil -> false
      index -> detected?(adapter, trace, {:serialize, Trace.label(trace), index, action}, opts)
    end
  end

  # The index of the first start of `action` that overlaps another op.
  defp overlapping_start({_trace, report}, action) do
    overlaps = overlaps(report)

    Enum.find_value(report.synced, fn
      %{kind: :start, action: ^action, index: index} -> if overlaps[index], do: index
      _entry -> nil
    end)
  end

  @doc """
  Describes a result's survivors and untested targets, one line each.
  """
  @spec format(result()) :: String.t()
  def format(%{survived: survived, untested: untested} = result) do
    never_overlap = Map.get(result, :never_overlap, [])

    Enum.map_join(survived ++ untested, "\n", fn
      {:interleaving, action} ->
        if action in never_overlap,
          do: "#{action} never overlaps another op in any trace",
          else: "serializing #{action} is never detected"

      other ->
        line(other)
    end)
  end

  defp line({:perturb, trace, index, key}),
    do: "perturbed #{inspect(key)} at #{trace} step #{index} was not detected"

  defp line({:drop, trace, index, action}),
    do: "dropped #{action} at #{trace} step #{index} was not detected"

  defp line({:key, key}), do: "key #{inspect(key)} never changes in any trace"
  defp line({:call, action}), do: "no step of #{action} changes the state"
  defp line({:var, var}), do: "variable #{inspect(var)} is never projected"

  @doc """
  Which ops of a replay overlap another op, from its `report`.

  Returns a map from the index of each `:start` step to whether another op
  was in flight at some point between that start and the op's completion
  (or the end of the trace, for an op that never completes). An op id
  reused after its completion is a new op.
  """
  @spec overlaps(Replay.report()) :: %{pos_integer() => boolean()}
  def overlaps(%{synced: synced}) do
    {overlaps, _in_flight} =
      Enum.reduce(synced, {%{}, %{}}, fn
        %{kind: :start, op: op, index: index}, {overlaps, in_flight} ->
          # It overlaps every op in flight, and they overlap it.
          others = Map.new(in_flight, fn {_op, started} -> {started, true} end)
          overlaps = overlaps |> Map.put(index, others != %{}) |> Map.merge(others)
          {overlaps, Map.put(in_flight, op, index)}

        %{kind: :complete, op: op}, {overlaps, in_flight} ->
          {overlaps, Map.delete(in_flight, op)}

        _entry, acc ->
          acc
      end)

    overlaps
  end

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
          {target, changed, index} <- candidates(kind, report),
          do: {target, changed, {trace, index}}

    found =
      Enum.reduce(candidates, %{}, fn
        {target, true, at}, found -> Map.put_new(found, target, at)
        _candidate, found -> found
      end)

    all = candidates |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    %{found: found, unchanged: Enum.reject(all, &Map.has_key?(found, &1))}
  end

  # A report's candidates in step order: {target, changed?, index}.
  defp candidates(:key, report) do
    for {entry, previous} <- with_previous(report),
        key <- Map.keys(entry.expected),
        do: {key, Map.fetch(entry.expected, key) != Map.fetch(previous, key), entry.index}
  end

  # A call is an {:ok, …} step or an op's completion, which changed the
  # state when it did; or an op's start, which "changed" it when its
  # completion did (a start rarely changes the visible state itself).
  # Advances aren't calls.
  defp candidates(:call, report) do
    pairs = with_previous(report)
    started = completions_changed(pairs)

    for {entry, previous} <- pairs, entry.kind in [:ok, :complete, :start] do
      changed =
        if entry.kind == :start,
          do: Map.get(started, entry.index, false),
          else: entry.expected != previous

      {entry.action, changed, entry.index}
    end
  end

  # For each start index: whether its op's completion changed the state.
  defp completions_changed(pairs) do
    {changed, _in_flight} =
      Enum.reduce(pairs, {%{}, %{}}, fn
        {%{kind: :start, op: op, index: index}, _previous}, {changed, in_flight} ->
          {changed, Map.put(in_flight, op, index)}

        {%{kind: :complete, op: op} = entry, previous}, {changed, in_flight} ->
          case Map.pop(in_flight, op) do
            {nil, in_flight} -> {changed, in_flight}
            {start, in_flight} -> {Map.put(changed, start, entry.expected != previous), in_flight}
          end

        _pair, acc ->
          acc
      end)

    changed
  end

  defp with_previous(%{synced: synced, initial_expected: initial}) do
    Enum.zip(synced, [initial | Enum.map(synced, & &1.expected)])
  end

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
  defp mutation({:serialize, _trace, index, _action}), do: {:serialize, index}

  defp caught?({:perturb, _trace, index, key}, failure),
    do: failure.index == index and String.contains?(failure.message, inspect(key))

  defp caught?({tag, _trace, index, _action}, failure) when tag in [:drop, :serialize],
    do: failure.index >= index
end
