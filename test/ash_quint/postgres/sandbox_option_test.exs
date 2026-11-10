defmodule AshQuint.Postgres.SandboxOption do
  @moduledoc false
  # Adapters and helpers for the sandbox: option tests.

  defmodule LockingAdapter do
    @moduledoc false
    # The toy adapter (faults: as there), which in init/2 tells
    # adapter_opts[:test] how many of its advisory locks Postgres holds
    # ({:locks, n}), then takes one more (a transaction-level one, held
    # until its transaction ends) and inserts a race_counters row, sent as
    # {:row, id}.
    use AshQuint.Adapter

    alias AshQuint.Postgres.{SandboxHelpers, SandboxOption}
    alias AshQuint.Test.ToyAdapter

    @impl true
    def init(trace, opts) do
      send(opts[:test], {:locks, SandboxOption.locks()})
      SandboxOption.lock()
      send(opts[:test], {:row, SandboxHelpers.open()})
      ToyAdapter.init(trace, opts)
    end

    @impl true
    defdelegate step(ctx, step), to: ToyAdapter

    @impl true
    defdelegate project(ctx), to: ToyAdapter

    @impl true
    defdelegate outcome(result), to: ToyAdapter
  end

  defmodule RowOpsAdapter do
    @moduledoc false
    # Inserts a race_counters row in init/2; each op reads it in its task,
    # gates, and returns its count, so an op that can't see the row raises.
    use AshQuint.Adapter

    import AshQuint.Postgres.SandboxHelpers

    alias AshQuint.{Gate, Step}

    @impl true
    def init(_trace, _opts), do: {:ok, %{id: open()}}

    @impl true
    def step(ctx, %Step{action_taken: "IncStart", nondet_picks: %{"op" => op}}) do
      call = fn ->
        read = count(ctx.id)
        Gate.checkpoint(:read)
        read
      end

      {:start, op, call, ctx}
    end

    def step(ctx, %Step{action_taken: "IncDone", nondet_picks: %{"op" => op}}),
      do: {:complete, op, ctx}

    @impl true
    def project(_ctx), do: %{}

    @impl true
    def outcome(0), do: :accepted
  end

  alias AshQuint.TestRepo
  alias Ecto.Adapters.SQL.Sandbox

  @key 424_242

  # The transaction-level advisory locks under @key, on every backend.
  def locks do
    %{rows: [[n]]} =
      TestRepo.query!(
        "select count(*) from pg_locks where locktype = 'advisory' and classid::bigint = $1",
        [@key]
      )

    n
  end

  def lock do
    n = System.unique_integer([:positive, :monotonic])
    TestRepo.query!("select pg_advisory_xact_lock($1, $2)", [@key, n])
  end

  def received(tag) do
    receive do
      {^tag, value} -> [value | received(tag)]
    after
      0 -> []
    end
  end

  # Runs `fun` on a connection of its own, rolled back afterwards.
  def fresh(fun) do
    :ok = Sandbox.checkout(TestRepo)

    try do
      fun.()
    after
      Sandbox.checkin(TestRepo)
    end
  end
end

defmodule AshQuint.Postgres.SandboxOptionTest do
  # sandbox: — each replay on a sandbox connection of its own. The tests
  # start no sandbox owner: the pool is in :manual mode, so the test
  # process owns no connection until a replay checks one out.
  use ExUnit.Case, async: true

  import AshQuint.Postgres.SandboxHelpers
  import AshQuint.Postgres.SandboxOption
  import AshQuint.Test.TraceBuilder

  alias AshQuint.{Explore, Replay, Sensitivity, TestRepo, Trace}
  alias AshQuint.Postgres.SandboxOption.{LockingAdapter, RowOpsAdapter}
  alias AshQuint.Test.FixtureRunner
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :postgres
  @moduletag :tmp_dir

  @config "test/fixtures/case/ash_quint.exs"
  @ok_traces "test/fixtures/case/ok/*.itf.json"

  defp explore(opts, tmp_dir) do
    Explore.run(
      %{runs: 10, seed: 1, budget: nil, failures: 1},
      [model: :ok, adapter: LockingAdapter, config: @config, batch: 4] ++
        [adapter_opts: [test: self()]] ++ opts,
      runner: FixtureRunner.runner(@ok_traces),
      build_dir: Path.join(tmp_dir, "build"),
      tmp_dir: Path.join(tmp_dir, "tmp")
    )
  end

  defp ok_traces do
    for path <- Path.wildcard(@ok_traces) |> Enum.sort(),
        do: Trace.load!(path, name: Path.basename(path), source: :random, seed: 7)
  end

  defp owner! do
    pid = Sandbox.start_owner!(TestRepo)
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  # No row of `ids` exists, and the locks are released. Checking a
  # connection in returns before its rollback has run, so the last
  # replay's lock may take a moment to go.
  defp released!(ids) do
    fresh(fn -> for id <- ids, do: assert(%{rows: []} = row(id)) end)
    assert eventually(fn -> fresh(&locks/0) == 0 end)
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end

  # Each replay finds at most the previous one's lock (see released!/1);
  # a replay that kept its connection would leave 0, 1, 2, … behind.
  defp bounded?(locks), do: Enum.all?(locks, &(&1 <= 1))

  defp row(id), do: TestRepo.query!("select 1 from race_counters where id = $1", [dump(id)])

  test "an explore run holds one trace's locks at a time", %{tmp_dir: tmp_dir} do
    report = explore([sandbox: TestRepo], tmp_dir)

    assert report.failures == [] and report.error == nil
    assert report.replayed == 10
    # Every trace found the locks of the ones before it released.
    locks = received(:locks)
    assert length(locks) == 10 and bounded?(locks)
    released!(received(:row))
  end

  test "without sandbox:, an explore run in the test's sandbox keeps every trace's locks",
       %{tmp_dir: tmp_dir} do
    owner!()
    report = explore([], tmp_dir)

    assert report.replayed == 10
    assert received(:locks) == Enum.to_list(0..9)
  end

  test "an explore run whose test has a connection fails before its first batch",
       %{tmp_dir: tmp_dir} do
    owner!()

    error = assert_raise ArgumentError, fn -> explore([sandbox: TestRepo], tmp_dir) end
    assert error.message =~ "explore of :ok has sandbox: AshQuint.TestRepo"
    assert error.message =~ "defp setup_sandbox(%{quint_explore: _}), do: :ok"
    assert received(:locks) == []
  end

  test "each sensitivity replay, clean and mutant, has a transaction of its own" do
    Sensitivity.check(LockingAdapter, ok_traces(),
      sandbox: TestRepo,
      adapter_opts: [test: self()]
    )

    locks = received(:locks)
    assert length(locks) > length(ok_traces())
    assert bounded?(locks)
    released!(received(:row))
  end

  test "a sensitivity check whose test has a connection fails before its first replay" do
    owner!()

    error =
      assert_raise ArgumentError, fn ->
        Sensitivity.check(LockingAdapter, ok_traces(),
          sandbox: TestRepo,
          adapter_opts: [test: self()]
        )
      end

    assert error.message =~ "the sensitivity check has sandbox: AshQuint.TestRepo"
    assert error.message =~ "quint_sensitivity: _"
    assert received(:locks) == []
  end

  test "a replay checks its connection in on pass, failure and raise" do
    states = [init(), inc(1, 1)]
    opts = [sandbox: TestRepo, adapter_opts: [test: self()]]

    assert {:ok, _report} = Replay.run(LockingAdapter, trace(states), opts)

    assert {:error, %{index: 1}} =
             Replay.run(LockingAdapter, trace(states),
               sandbox: TestRepo,
               adapter_opts: [test: self(), faults: [:off_by_one]]
             )

    assert_raise RuntimeError, "db down", fn ->
      Replay.run(LockingAdapter, trace(states),
        sandbox: TestRepo,
        adapter_opts: [test: self(), faults: [:raise]]
      )
    end

    locks = received(:locks)
    assert length(locks) == 3 and bounded?(locks)
    released!(received(:row))
  end

  test "a replay whose test has a connection takes none and gives none back" do
    owner!()

    assert {:ok, _report} =
             Replay.run(LockingAdapter, trace([init(), inc(1, 1)]),
               sandbox: TestRepo,
               adapter_opts: [test: self()]
             )

    # Still in the test's transaction: its row and lock are there.
    assert [id] = received(:row)
    assert %{rows: [[1]]} = row(id)
    assert locks() == 1
    assert Sandbox.checkout(TestRepo) == {:already, :allowed}
  end

  test "op tasks reach the replay's connection" do
    states = [init(), inc_start(0, "o1", 1), inc_start(0, "o2", 1), inc_done(0, "o1")]
    assert {:ok, _report} = Replay.run(RowOpsAdapter, trace(states), sandbox: TestRepo)
  end
end

defmodule AshQuint.Postgres.SandboxOptionSharedTest do
  # sandbox: in shared mode (an async: false template's start_owner!(…,
  # shared: true)): the test process isn't allowed on the shared
  # connection, so the replay checks out its own, and allows its op tasks
  # on it, which would otherwise reach the shared owner's.
  use ExUnit.Case, async: false

  import AshQuint.Test.TraceBuilder

  alias AshQuint.Postgres.SandboxOption.RowOpsAdapter
  alias AshQuint.{Replay, TestRepo}
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :postgres

  setup do
    pid = Sandbox.start_owner!(TestRepo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  test "op tasks reach the replay's connection, not the shared one" do
    states = [init(), inc_start(0, "o1", 1), inc_start(0, "o2", 1), inc_done(0, "o1")]
    assert {:ok, _report} = Replay.run(RowOpsAdapter, trace(states), sandbox: TestRepo)
  end
end
