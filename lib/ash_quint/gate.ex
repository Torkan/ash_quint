defmodule AshQuint.Gate do
  @moduledoc """
  Gates: named points in the system's code where a replay's op task stops
  until the replay releases it.

      AshQuint.Gate.checkpoint(:after_read)

  When an adapter's `step/2` returns `{:start, op, call, ctx}`,
  `AshQuint.Replay` runs `call` in an **op task**, a process linked to the
  test process, with `$callers` set as `Task` sets it. Each
  `checkpoint/1` the call reaches stops it there and tells the replay; the
  replay compares the state once every op in flight has stopped at a gate
  (or finished), and releases the op at the step that advances or
  completes it. That is how a trace's interleaving is reproduced: two ops
  that both read before either writes, say.

  Place gates where the race can happen: in an Ash change, in the code the
  system's actions call, or in a test implementation of a behaviour the
  system already calls (a mail client, a payment gateway). Outside an op
  task, `checkpoint/1` returns `:ok` at once, after an ETS lookup per pid in
  `[self() | $callers]`, so it can stay in code compiled for test. Gate
  names are the adapter's own atoms (or tuples such as `{:query, 1}`).

  A gate that isn't released within the replay's `:gate_timeout` returns
  anyway, and the replay fails at the step it is on. When the replay
  cancels an op (at the end of the trace, or on a failure), a gated op
  exits from `checkpoint/1` with `{:shutdown, :ash_quint_cancelled}`.

  Two other ways to place gates: the Ash change `AshQuint.Ash.Gate`
  (`change {AshQuint.Ash.Gate, at: :after_read}`), and telemetry gates,
  `AshQuint.Gate.Telemetry`, which stop an op task at the telemetry events
  it emits (Ecto queries, Ash action spans). A call can record what it may
  wait on with `put_info/2`, for the adapter's `blocked?/2`.

  The op tasks are registered in an ETS table owned by the `:ash_quint`
  application. The functions without docs here are for `AshQuint.Replay`.
  """

  alias AshQuint.Gate.Table

  # AshQuint.Ash is compiled only when Ash is loaded; context_transfer/0
  # checks for it.
  @compile {:no_warn_undefined, AshQuint.Ash}

  @current_replay :ash_quint_replay

  @typedoc "A gate name: the adapter's own atom (or a tuple such as `{:query, 1}`)."
  @type name :: atom() | tuple()

  @doc """
  Stops the calling op task at the gate `name` until the replay releases
  it; returns `:ok`.

  The op is found by looking up the calling process, then each pid in its
  `$callers`, in the gate table, so `Task`s the system starts from an op
  task gate their op too. Outside an op task (and when no replay ever ran)
  it returns `:ok` at once. It never raises: a name that isn't an atom or a
  tuple, or a missing table, returns `:ok`. When the replay cancels the op,
  it exits the calling process with `{:shutdown, :ash_quint_cancelled}`.
  """
  @spec checkpoint(name()) :: :ok
  def checkpoint(name) when is_atom(name) or is_tuple(name) do
    case gate(name, :any) do
      :cancel -> exit({:shutdown, :ash_quint_cancelled})
      :ok -> :ok
    end
  end

  def checkpoint(_name), do: :ok

  @doc """
  Records `value` under `key` in the info of the calling op task's op;
  returns `:ok`.

  The replay passes the info to the adapter's `blocked?/2`, so a call can
  say what it may wait on: the Postgres backend of its connection, say
  (`AshQuint.Ash.pg_backend_pid/1` does that). Like `checkpoint/1`, it
  finds the op through `$callers`, does nothing outside an op task and
  never raises.
  """
  @spec put_info(term(), term()) :: :ok
  def put_info(key, value) do
    case lookup(Table.name(), [self() | callers()]) do
      {pid, _replay, _ref, _op, _mode, _timeout, info} ->
        :ets.update_element(Table.name(), pid, {7, Map.put(info, key, value)})
        :ok

      nil ->
        :ok
    end
  catch
    _kind, _reason -> :ok
  end

  @doc false
  # The info of the op task `pid` (%{} when it has no row).
  @spec info(pid()) :: map()
  def info(pid) do
    case lookup(Table.name(), [pid]) do
      {_pid, _replay, _ref, _op, _mode, _timeout, info} -> info
      nil -> %{}
    end
  end

  @doc """
  The replay running in the calling process (its ref), or `nil`.

  `AshQuint.Replay` sets it before it calls the adapter's `init/2` and
  clears it when the replay ends, so an adapter can scope what it attaches
  to its own replay, as `AshQuint.Gate.Telemetry.attach/2` does.
  """
  @spec current_replay() :: reference() | nil
  def current_replay, do: Process.get(@current_replay)

  @doc false
  # Sets the current replay; returns the previous one.
  @spec put_current_replay(reference() | nil) :: reference() | nil
  def put_current_replay(nil), do: Process.delete(@current_replay)
  def put_current_replay(ref), do: Process.put(@current_replay, ref)

  @doc false
  # The op of the replay `ref` that the calling process belongs to (itself
  # or through $callers), or nil.
  @spec current_op(reference()) :: String.t() | nil
  def current_op(ref) do
    case lookup(Table.name(), [self() | callers()]) do
      {_pid, _replay, ^ref, op, _mode, _timeout, _info} -> op
      _other -> nil
    end
  catch
    _kind, _reason -> nil
  end

  @doc false
  # checkpoint/1 for the ops of the replay `ref` only. Returns :cancel
  # instead of exiting when the op is cancelled.
  @spec scoped_checkpoint(reference(), name()) :: :ok | :cancel
  def scoped_checkpoint(ref, name), do: gate(name, ref)

  defp gate(name, scope) do
    case lookup(Table.name(), [self() | callers()]) do
      {_pid, replay, ref, op, :gated, timeout, _info} when scope in [:any, ref] ->
        wait(replay, ref, op, name, timeout)

      _other ->
        :ok
    end
  catch
    _kind, _reason -> :ok
  end

  defp wait(replay, ref, op, name, timeout) do
    reply = make_ref()
    send(replay, {:ash_quint_gate, ref, op, name, self(), reply})

    receive do
      {^reply, :go} -> :ok
      {:ash_quint_cancel, ^ref} -> :cancel
    after
      timeout ->
        send(replay, {:ash_quint_gate_timeout, ref, op, name})
        :ok
    end
  end

  defp callers do
    case Process.get(:"$callers") do
      callers when is_list(callers) -> callers
      _other -> []
    end
  end

  @doc false
  # The first row of `table` for a pid of `pids`, or nil (also when the
  # table doesn't exist).
  @spec lookup(atom(), [term()]) :: tuple() | nil
  def lookup(table, pids) do
    if :ets.whereis(table) == :undefined do
      nil
    else
      Enum.find_value(pids, fn
        pid when is_pid(pid) -> List.first(:ets.lookup(table, pid))
        _other -> nil
      end)
    end
  end

  # Op tasks. The replay keeps its ops as %{op => entry}, an entry being a
  # map with at least :pid and :status (and :free once freed). These
  # functions only update :status and :free.

  @typedoc false
  @type result :: {:returned, term()} | {:raised, :error | :exit | :throw, term(), list()}

  @typedoc false
  @type status ::
          :running | :blocked | {:gate, name(), pid(), reference()} | {:finished, result()}

  @typedoc false
  @type ops :: %{
          optional(String.t()) => %{required(:pid) => pid(), required(:status) => status()}
        }

  @doc false
  # Starts `call` in an op task linked to the caller, with `$callers` set
  # as `Task` sets it. Options: :gate_timeout (ms, default 5_000) and :mode
  # (:gated or :free, default :gated). The row is in the table before the
  # call runs.
  @spec start_op(reference(), String.t(), (-> term()), keyword()) :: pid()
  def start_op(ref, op, call, opts) do
    replay = self()
    callers = [replay | callers()]
    go = make_ref()
    transfer = context_transfer()

    pid =
      spawn_link(fn ->
        Process.put(:"$callers", callers)

        receive do
          ^go ->
            # Inside run/1, so a raising tracer becomes the op's result.
            result =
              run(fn ->
                transfer.()
                call.()
              end)

            send(replay, {:ash_quint_op, ref, op, result})
        end
      end)

    row =
      {pid, replay, ref, op, Keyword.get(opts, :mode, :gated),
       Keyword.get(opts, :gate_timeout, 5_000), %{}}

    if :ets.whereis(Table.name()) == :undefined do
      raise "the :ash_quint application isn't started, so there is no gate table"
    end

    :ets.insert(Table.name(), row)
    send(pid, go)
    pid
  end

  # The Ash tracer span context of the caller, to set in the op task
  # (AshQuint.Ash is compiled only when Ash is loaded).
  defp context_transfer do
    if Code.ensure_loaded?(AshQuint.Ash),
      do: AshQuint.Ash.transfer_context(),
      else: fn -> :ok end
  end

  defp run(call) do
    {:returned, call.()}
  catch
    :exit, {:shutdown, :ash_quint_cancelled} = reason -> exit(reason)
    kind, reason -> {:raised, kind, reason, __STACKTRACE__}
  end

  @doc false
  # Waits until no op is :running, or `timeout` ms. Handles every gate,
  # result and gate-timeout message of `ref` that arrives meanwhile (and
  # those already there): a gate puts its op :at_gate (a freed op is
  # released at once), a result makes it :finished. With `blocked?`, a
  # function of an op and its entry, every running op is checked every
  # 10 ms, and those it says are blocked become :blocked. Returns the ops
  # and the gate timeouts reported, as {op, name}, in order.
  @spec await_settled(
          reference(),
          ops(),
          non_neg_integer(),
          (String.t(), map() -> boolean()) | nil
        ) :: {ops(), [{String.t(), name()}]}
  def await_settled(ref, ops, timeout, blocked? \\ nil)

  def await_settled(ref, ops, timeout, nil) do
    await(ref, ops, &settled?/1, deadline(timeout), [])
  end

  def await_settled(ref, ops, timeout, blocked?) do
    poll(ref, ops, blocked?, deadline(timeout), [])
  end

  @poll 10

  # Waits up to @poll ms at a time, then asks blocked? about the ops still
  # running.
  defp poll(ref, ops, blocked?, deadline, timeouts) do
    now = System.monotonic_time(:millisecond)
    {ops, timeouts} = await(ref, ops, &settled?/1, min(now + @poll, deadline), timeouts)

    ops =
      Map.new(ops, fn
        {op, %{status: :running} = entry} ->
          if blocked?.(op, entry), do: {op, %{entry | status: :blocked}}, else: {op, entry}

        other ->
          other
      end)

    if settled?(ops) or System.monotonic_time(:millisecond) >= deadline,
      do: await(ref, ops, &settled?/1, deadline(0), timeouts),
      else: poll(ref, ops, blocked?, deadline, timeouts)
  end

  @doc false
  # Waits until `op` is :finished, or `timeout` ms, handling messages as
  # await_settled/3 does.
  @spec await_finished(reference(), ops(), String.t(), non_neg_integer()) ::
          {ops(), [{String.t(), name()}]}
  def await_finished(ref, ops, op, timeout) do
    await(ref, ops, &match?(%{^op => %{status: {:finished, _}}}, &1), deadline(timeout), [])
  end

  defp settled?(ops), do: not Enum.any?(ops, fn {_op, entry} -> entry.status == :running end)

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp await(ref, ops, done?, deadline, timeouts) do
    wait = if done?.(ops), do: 0, else: max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:ash_quint_gate, ^ref, op, name, gate_pid, reply} ->
        await(ref, at_gate(ops, op, name, gate_pid, reply), done?, deadline, timeouts)

      {:ash_quint_op, ^ref, op, result} ->
        ops = update(ops, op, &%{&1 | status: {:finished, result}})
        await(ref, ops, done?, deadline, timeouts)

      {:ash_quint_gate_timeout, ^ref, op, name} ->
        await(ref, ops, done?, deadline, timeouts ++ [{op, name}])
    after
      wait -> {ops, timeouts}
    end
  end

  defp at_gate(ops, op, name, gate_pid, reply) do
    case ops do
      %{^op => %{free: true}} ->
        send(gate_pid, {reply, :go})
        ops

      %{^op => %{status: {:finished, _result}}} ->
        ops

      %{^op => _entry} ->
        update(ops, op, &%{&1 | status: {:gate, name, gate_pid, reply}})

      _other ->
        ops
    end
  end

  defp update(ops, op, fun) do
    case ops do
      %{^op => entry} -> %{ops | op => fun.(entry)}
      _other -> ops
    end
  end

  @doc false
  # Releases `op` from its gate: it runs to its next gate or its result.
  @spec release(ops(), String.t()) :: ops()
  def release(ops, op) do
    case ops[op] do
      %{status: {:gate, _name, gate_pid, reply}} ->
        send(gate_pid, {reply, :go})
        update(ops, op, &%{&1 | status: :running})

      _other ->
        ops
    end
  end

  @doc false
  # Frees `op`: every gate it reaches from now on returns at once, and the
  # gate it is held at is released.
  @spec free(ops(), String.t()) :: ops()
  def free(ops, op) do
    case ops[op] do
      %{pid: pid} ->
        free_pid(pid)
        ops |> update(op, &Map.put(&1, :free, true)) |> release(op)

      nil ->
        ops
    end
  end

  @doc false
  # Marks the op task `pid` free in the table: its gates return at once.
  @spec free_pid(pid()) :: :ok
  def free_pid(pid) do
    :ets.update_element(Table.name(), pid, {5, :free})
    :ok
  catch
    :error, _reason -> :ok
  end

  @doc false
  # Waits for the op task `pid`, which has sent its result, to exit, and
  # deletes its row.
  @spec forget(pid()) :: :ok
  def forget(pid) do
    monitor = Process.monitor(pid)

    receive do
      {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
    end

    :ets.delete(Table.name(), pid)
    :ok
  end

  @doc false
  # Stops every op task of the replay `ref`: those in `ops` and those in
  # the gate table. Each is unlinked first (an op exiting with :shutdown or
  # :killed would otherwise kill the caller), then sent a cancel, which
  # makes a gated op exit from checkpoint/1, then given 100 ms to exit
  # before it is killed. Returns once every op task is dead, with no table
  # rows and no messages of `ref` left. Idempotent.
  @spec cancel_all(reference(), ops()) :: :ok
  def cancel_all(ref, ops) do
    known = Enum.flat_map(ops, fn {_op, entry} -> [entry.pid | gate_pids(entry.status)] end)
    pids = Enum.uniq(known ++ table_pids(ref))

    Enum.each(pids, &Process.unlink/1)
    Enum.each(pids, &send(&1, {:ash_quint_cancel, ref}))

    monitors = Map.new(pids, &{Process.monitor(&1), &1})
    alive = await_down(monitors, deadline(100))
    Enum.each(alive, fn {_monitor, pid} -> Process.exit(pid, :kill) end)
    await_down(alive, :infinity)

    if :ets.whereis(Table.name()) != :undefined,
      do: :ets.match_delete(Table.name(), {:_, :_, ref, :_, :_, :_, :_})

    flush(ref)
  end

  defp gate_pids({:gate, _name, gate_pid, _reply}), do: [gate_pid]
  defp gate_pids(_status), do: []

  defp table_pids(ref) do
    if :ets.whereis(Table.name()) == :undefined,
      do: [],
      else: :ets.select(Table.name(), [{{:"$1", :_, ref, :_, :_, :_, :_}, [], [:"$1"]}])
  end

  defp await_down(monitors, _deadline) when monitors == %{}, do: monitors

  defp await_down(monitors, deadline) do
    wait =
      if deadline == :infinity,
        do: :infinity,
        else: max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, monitor, :process, _pid, _reason} when is_map_key(monitors, monitor) ->
        await_down(Map.delete(monitors, monitor), deadline)
    after
      wait -> monitors
    end
  end

  defp flush(ref) do
    receive do
      {:ash_quint_gate, ^ref, _op, _name, _pid, _reply} -> flush(ref)
      {:ash_quint_op, ^ref, _op, _result} -> flush(ref)
      {:ash_quint_gate_timeout, ^ref, _op, _name} -> flush(ref)
    after
      0 -> :ok
    end
  end
end
