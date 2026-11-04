defmodule AshQuint.Test.Mutex do
  @moduledoc false
  # A lock that blocks the caller until it is free. The holder's death
  # frees it.
  use GenServer

  def start_link, do: GenServer.start_link(__MODULE__, nil)
  def lock(mutex), do: GenServer.call(mutex, :lock, :infinity)
  def unlock(mutex), do: GenServer.call(mutex, :unlock)
  def stop(mutex), do: GenServer.stop(mutex)

  @impl true
  def init(nil), do: {:ok, %{holder: nil, waiting: :queue.new()}}

  @impl true
  def handle_call(:lock, {pid, _tag}, %{holder: nil} = state),
    do: {:reply, :ok, %{state | holder: {pid, Process.monitor(pid)}}}

  def handle_call(:lock, from, state),
    do: {:noreply, %{state | waiting: :queue.in(from, state.waiting)}}

  def handle_call(:unlock, {pid, _tag}, %{holder: {pid, monitor}} = state) do
    Process.demonitor(monitor, [:flush])
    {:reply, :ok, next(state)}
  end

  @impl true
  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %{holder: {_holder, monitor}} = state
      ),
      do: {:noreply, next(state)}

  def handle_info({:DOWN, _monitor, :process, _pid, _reason}, state), do: {:noreply, state}

  defp next(state) do
    case :queue.out(state.waiting) do
      {{:value, {pid, _tag} = from}, waiting} ->
        GenServer.reply(from, :ok)
        %{state | holder: {pid, Process.monitor(pid)}, waiting: waiting}

      {:empty, _waiting} ->
        %{state | holder: nil}
    end
  end
end

defmodule AshQuint.Test.ConcurrentToyAdapter do
  @moduledoc false
  # A counter whose state lives in an Agent, so op tasks can reach it. An
  # inc is rejected with "too_big" when the count would exceed 3.
  #
  #   IncStart({op, by})  {:start, op, call, ctx}: call is inc/2
  #   IncRead({op})       {:advance, op, ctx}
  #   IncDone({op})       {:complete, op, ctx}
  #   Inc({by})           {:ok, inc/2, ctx}, in the test process
  #   Peek                {:skip, ctx}; with :peek_locks, reads under the lock
  #   WaitOp({op})        {:skip, ctx} once op's task has exited
  #   Begin(by)           {:pending, ctx}
  #   Commit              {:ok, inc/2, ctx} of the pending Begin
  #
  # A correct inc gates at :requested, then updates atomically. `faults:`
  # breaks it on purpose:
  #
  #   :lost_update     reads, gates at :after_read, writes read + by (the
  #                    limit is checked on the stale read)
  #   :two_gates       gates at :requested, reads, gates at :after_read, writes
  #   :visible_early   writes before its gate
  #   :no_gate         never gates
  #   {:raise, op}     op raises "boom" after its gate
  #   :locking         takes the lock before reading, gates at :after_read,
  #                    writes and unlocks
  #   :peek_locks      Peek takes the lock
  #   :project_raises  project/1 raises once an op has started
  #
  # `start_opts:` and `advance_opts:` map op ids to the options returned
  # with :start and :advance. `test:` is a pid that finish/2 sends
  # {:toy_finish, result, alive} to, alive being Process.alive?/1 of every
  # op task's pid.
  use AshQuint.Adapter

  alias AshQuint.Gate
  alias AshQuint.Step
  alias AshQuint.Test.Mutex

  @limit 3

  @impl true
  def init(_trace, opts) do
    {:ok, agent} = Agent.start_link(fn -> %{count: 0, pids: %{}} end)
    {:ok, mutex} = Mutex.start_link()

    {:ok,
     %{
       agent: agent,
       mutex: mutex,
       faults: Keyword.get(opts, :faults, []),
       start_opts: Keyword.get(opts, :start_opts, %{}),
       advance_opts: Keyword.get(opts, :advance_opts, %{}),
       pending: nil,
       test: Keyword.get(opts, :test)
     }}
  end

  @impl true
  def step(ctx, %Step{action_taken: "IncStart", nondet_picks: %{"op" => op, "by" => by}}) do
    call = fn ->
      pid = self()
      Agent.update(ctx.agent, &put_in(&1, [:pids, op], pid))
      inc(ctx, op, by)
    end

    case Map.get(ctx.start_opts, op, []) do
      [] -> {:start, op, call, ctx}
      opts -> {:start, op, call, ctx, opts}
    end
  end

  def step(ctx, %Step{action_taken: "IncRead", nondet_picks: %{"op" => op}}) do
    case Map.get(ctx.advance_opts, op, []) do
      [] -> {:advance, op, ctx}
      opts -> {:advance, op, ctx, opts}
    end
  end

  def step(ctx, %Step{action_taken: "IncDone", nondet_picks: %{"op" => op}}),
    do: {:complete, op, ctx}

  def step(ctx, %Step{action_taken: "Inc", nondet_picks: %{"by" => by}}),
    do: {:ok, inc(ctx, nil, by), ctx}

  def step(ctx, %Step{action_taken: "Peek"}) do
    if :peek_locks in ctx.faults do
      Mutex.lock(ctx.mutex)
      count = count(ctx)
      Mutex.unlock(ctx.mutex)
      {:ok, {:ok, count}, ctx}
    else
      {:skip, ctx}
    end
  end

  def step(ctx, %Step{action_taken: "Begin", nondet_picks: %{"value" => by}}),
    do: {:pending, %{ctx | pending: by}}

  def step(%{pending: by} = ctx, %Step{action_taken: "Commit"}) when is_integer(by),
    do: {:ok, atomic_inc(ctx, by), %{ctx | pending: nil}}

  def step(ctx, %Step{action_taken: "WaitOp", nondet_picks: %{"op" => op}}) do
    pid = Agent.get(ctx.agent, & &1.pids[op])
    monitor = Process.monitor(pid)

    receive do
      {:DOWN, ^monitor, :process, _pid, _reason} -> {:skip, ctx}
    end
  end

  defp inc(ctx, op, by) do
    faults = ctx.faults

    cond do
      :lost_update in faults ->
        read = count(ctx)
        Gate.checkpoint(:after_read)
        write(ctx, read, by)

      :two_gates in faults ->
        Gate.checkpoint(:requested)
        read = count(ctx)
        Gate.checkpoint(:after_read)
        write(ctx, read, by)

      :locking in faults ->
        Mutex.lock(ctx.mutex)
        read = count(ctx)
        Gate.checkpoint(:after_read)
        result = write(ctx, read, by)
        Mutex.unlock(ctx.mutex)
        result

      :visible_early in faults ->
        result = write(ctx, count(ctx), by)
        Gate.checkpoint(:requested)
        result

      true ->
        unless :no_gate in faults, do: Gate.checkpoint(:requested)
        if {:raise, op} in faults, do: raise("boom")
        atomic_inc(ctx, by)
    end
  end

  defp count(ctx), do: Agent.get(ctx.agent, & &1.count)

  defp write(_ctx, read, by) when read + by > @limit, do: {:rejected, "too_big"}

  defp write(ctx, read, by) do
    Agent.update(ctx.agent, &%{&1 | count: read + by})
    {:ok, read + by}
  end

  defp atomic_inc(ctx, by) do
    Agent.get_and_update(ctx.agent, fn
      %{count: count} = state when count + by > @limit -> {{:rejected, "too_big"}, state}
      %{count: count} = state -> {{:ok, count + by}, %{state | count: count + by}}
    end)
  end

  @impl true
  def project(ctx) do
    state = Agent.get(ctx.agent, & &1)

    if :project_raises in ctx.faults and state.pids != %{},
      do: raise("project blew up")

    %{"count" => state.count}
  end

  @impl true
  def outcome({:ok, _}), do: :accepted
  def outcome({:rejected, code}), do: {:rejected, code}

  @impl true
  def finish(ctx, result) do
    pids = Agent.get(ctx.agent, & &1.pids)

    if ctx.test,
      do:
        send(
          ctx.test,
          {:toy_finish, result, Enum.map(pids, fn {_op, pid} -> Process.alive?(pid) end)}
        )

    Agent.stop(ctx.agent)
    Mutex.stop(ctx.mutex)
    :ok
  end
end

defmodule AshQuint.Test.ConcurrentToyAdapterBlind do
  @moduledoc false
  # The concurrent toy adapter with a projection blind until completion:
  # expected/2 takes an IncStart's count from the system instead of the
  # model, so an op that runs to completion at its start goes unnoticed
  # there.
  use AshQuint.Adapter

  alias AshQuint.Step
  alias AshQuint.Test.ConcurrentToyAdapter

  @impl true
  defdelegate init(trace, opts), to: ConcurrentToyAdapter

  @impl true
  defdelegate step(ctx, step), to: ConcurrentToyAdapter

  @impl true
  defdelegate project(ctx), to: ConcurrentToyAdapter

  @impl true
  def expected(ctx, %Step{action_taken: "IncStart"}), do: ConcurrentToyAdapter.project(ctx)
  def expected(_ctx, %Step{state: state}), do: Map.take(state, ["count"])

  @impl true
  defdelegate outcome(result), to: ConcurrentToyAdapter

  @impl true
  defdelegate finish(ctx, result), to: ConcurrentToyAdapter
end
