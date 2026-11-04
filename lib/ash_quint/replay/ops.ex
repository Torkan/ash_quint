defmodule AshQuint.Replay.Ops do
  @moduledoc false
  # The replay's ops in flight: %{op => entry}, where an entry is
  #
  #   %{pid: pid, started_at: index, since: index, status: status, opts: opts}
  #
  # (plus free: true once freed). `status` is AshQuint.Gate's; `since` is the
  # step at which the op took its current status. AshQuint.Gate does the
  # process work; this module turns its results into failure lines.

  alias AshQuint.{Gate, Step}

  @type entry :: %{
          required(:pid) => pid(),
          required(:started_at) => pos_integer(),
          required(:since) => pos_integer(),
          required(:status) => Gate.status(),
          required(:opts) => keyword(),
          optional(:free) => boolean()
        }

  @type t :: %{optional(String.t()) => entry()}

  @type timeouts :: %{
          settle: non_neg_integer(),
          step: non_neg_integer(),
          complete: non_neg_integer(),
          gate: non_neg_integer()
        }

  @doc false
  # Starts `op` at `step` and waits until it settles.
  @spec start(reference(), timeouts(), t(), Step.t(), String.t(), (-> term()), keyword()) ::
          {t(), [String.t()]}
  def start(ref, timeouts, ops, step, op, call, opts) do
    pid = Gate.start_op(ref, op, call, gate_timeout: timeouts.gate)

    entry = %{
      pid: pid,
      started_at: step.index,
      since: step.index,
      status: :running,
      opts: opts
    }

    settle(ref, timeouts, Map.put(ops, op, entry), step)
  end

  @doc false
  # Releases `op` from its gate and waits until it settles again. Its
  # `may_block:` becomes the one given here, when given.
  @spec advance(reference(), timeouts(), t(), Step.t(), String.t(), keyword()) ::
          {t(), [String.t()]}
  def advance(ref, timeouts, ops, step, op, opts) do
    ops =
      case Keyword.fetch(opts, :may_block) do
        {:ok, may_block} -> update_in(ops[op].opts, &Keyword.put(&1, :may_block, may_block))
        :error -> ops
      end

    settle(ref, timeouts, ops |> Gate.release(op) |> wake(), step, ops)
  end

  # A release can unblock a blocked op, so blocked ops are awaited again.
  defp wake(ops) do
    Map.new(ops, fn
      {op, %{status: :blocked} = entry} -> {op, %{entry | status: :running}}
      other -> other
    end)
  end

  @doc false
  # Releases `op` through every gate and waits for its result. Returns the
  # ops without `op` (its task is dead), the result (nil when it didn't
  # return in time) and the failure lines.
  @spec complete(reference(), timeouts(), t(), Step.t(), String.t()) ::
          {t(), Gate.result() | nil, [String.t()]}
  def complete(ref, timeouts, ops, step, op) do
    {ops, timeouts_seen} = ref |> Gate.await_finished(Gate.free(ops, op), op, timeouts.complete)
    gate_lines = Enum.map(timeouts_seen, &gate_timeout_line(&1, timeouts))

    case ops[op] do
      %{status: {:finished, result}, pid: pid} ->
        Gate.forget(pid)
        {ops, lines} = settle(ref, timeouts, ops |> Map.delete(op) |> wake(), step, ops)
        {ops, result, gate_lines ++ lines}

      %{} ->
        line = "op #{inspect(op)} did not return within #{timeouts.complete}ms of its completion"
        {ops, nil, gate_lines ++ [line]}
    end
  end

  @doc false
  # Waits until every running op has settled (at a gate or finished), up
  # to the settle timeout, and handles the messages already there. Returns
  # the ops and a line per problem: gate timeouts, ops that raised, ops
  # that didn't settle.
  # `before` is what `since` is compared with: the ops before this step
  # released or woke any of them.
  @spec settle(reference(), timeouts(), t(), Step.t(), t() | nil) :: {t(), [String.t()]}
  def settle(ref, timeouts, ops, step, before \\ nil) do
    before = before || ops
    {settled, timeouts_seen} = Gate.await_settled(ref, ops, timeouts.settle)

    # An op that may block and didn't settle counts as blocked.
    settled =
      Map.new(settled, fn
        {op, %{status: :running} = entry} ->
          if entry.opts[:may_block] == true,
            do: {op, %{entry | status: :blocked}},
            else: {op, entry}

        other ->
          other
      end)

    settled = since(before, settled, step)
    unsettled = for {op, %{status: :running}} <- Enum.sort(settled), do: op

    raised =
      for {op, %{status: {:finished, {:raised, _, _, _} = result}}} <- Enum.sort(settled),
          not match?(%{status: {:finished, _}}, before[op]),
          do: raised_line(op, result)

    unsettled_lines =
      for op <- unsettled do
        others = Map.delete(settled, op)

        "op #{inspect(op)} did not settle within #{timeouts.settle}ms" <>
          if(others == %{}, do: "", else: "; " <> in_flight_line(others))
      end

    {settled,
     Enum.map(timeouts_seen, &gate_timeout_line(&1, timeouts)) ++ raised ++ unsettled_lines}
  end

  defp since(before, ops, step) do
    Map.new(ops, fn {op, entry} ->
      if before[op] && before[op].status != entry.status,
        do: {op, %{entry | since: step.index}},
        else: {op, entry}
    end)
  end

  @doc false
  @spec raised_line(String.t(), Gate.result()) :: String.t()
  def raised_line(op, {:raised, kind, reason, stacktrace}) do
    "op #{inspect(op)} raised: " <> Exception.format_banner(kind, reason, stacktrace)
  end

  defp gate_timeout_line({op, name}, timeouts) do
    "gate #{inspect(name)} of op #{inspect(op)} was not released within #{timeouts.gate}ms"
  end

  @doc false
  # `in flight: "o1" at gate :after_read (since step 1), …`
  @spec in_flight_line(t()) :: String.t()
  def in_flight_line(ops) do
    "in flight: " <>
      Enum.map_join(Enum.sort(ops), ", ", fn {op, entry} ->
        "#{inspect(op)} #{describe(entry.status)} (since step #{entry.since})"
      end)
  end

  defp describe({:gate, name, _pid, _reply}), do: "at gate #{inspect(name)}"
  defp describe({:finished, _result}), do: "finished"
  defp describe(status), do: Atom.to_string(status)

  @doc false
  # The failure's in_flight field.
  @spec in_flight(t()) :: [AshQuint.Replay.in_flight()]
  def in_flight(ops) do
    for {op, entry} <- Enum.sort(ops) do
      at_gate =
        case entry.status do
          {:gate, name, _pid, _reply} -> name
          _status -> nil
        end

      %{op: op, started_at: entry.started_at, at_gate: at_gate}
    end
  end

  @doc false
  # Starts a watchdog for a step/2 call made while ops are in flight (nil
  # when none are). If the call hasn't returned within the step timeout,
  # it frees every gated op, so a call blocked on what one of them holds
  # can return, and tells the replay which ops were held where.
  @spec watch(t(), timeouts()) :: {pid(), reference()} | nil
  def watch(ops, _timeouts) when ops == %{}, do: nil

  def watch(ops, timeouts) do
    replay = self()
    ref = make_ref()

    held =
      for {op, %{status: {:gate, name, gate_pid, reply}, pid: pid}} <- Enum.sort(ops),
          do: {op, name, pid, gate_pid, reply}

    pid =
      spawn(fn ->
        monitor = Process.monitor(replay)

        receive do
          {^ref, :stop} -> send(replay, {ref, :stopped})
          {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
        after
          timeouts.step ->
            Enum.each(held, fn {_op, _name, pid, gate_pid, reply} ->
              Gate.free_pid(pid)
              send(gate_pid, {reply, :go})
            end)

            send(replay, {:ash_quint_watchdog, ref, Enum.map(held, &{elem(&1, 0), elem(&1, 1)})})
        end
      end)

    {pid, ref}
  end

  @doc false
  # Stops the watchdog: :ok, or {:fired, [{op, gate}]} when it fired.
  @spec unwatch({pid(), reference()} | nil) :: :ok | {:fired, [{String.t(), Gate.name()}]}
  def unwatch(nil), do: :ok

  # The watchdog sends exactly one of {ref, :stopped} and its report.
  def unwatch({pid, ref}) do
    send(pid, {ref, :stop})

    receive do
      {^ref, :stopped} -> :ok
      {:ash_quint_watchdog, ^ref, held} -> {:fired, held}
    end
  end

  @doc false
  # The ops after the watchdog fired: the held ones are free and running.
  # Settles them, and returns the watchdog's line first.
  @spec fired(reference(), timeouts(), t(), Step.t(), [{String.t(), Gate.name()}]) ::
          {t(), [String.t()]}
  def fired(ref, timeouts, ops, step, held) do
    ops =
      Enum.reduce(held, ops, fn {op, _name}, ops ->
        update_in(ops[op], &(&1 |> Map.put(:free, true) |> Map.put(:status, :running)))
      end)

    {ops, lines} = settle(ref, timeouts, ops, step)

    while =
      Enum.map_join(held, " and ", fn {op, name} ->
        "#{inspect(op)} was held at gate #{inspect(name)}"
      end)

    line =
      "step #{step.index} (#{step.action_taken}) blocked for #{timeouts.step}ms" <>
        if(held == [], do: "", else: " while " <> while)

    {ops, [line | lines]}
  end
end
