defmodule AshQuint.GateTelemetryTest do
  use ExUnit.Case, async: true

  import AshQuint.Test.TraceBuilder

  alias AshQuint.Gate
  alias AshQuint.Gate.Telemetry
  alias AshQuint.Replay
  alias AshQuint.Test.RaceCounter

  # Fires [:ash_quint_test, :tick] from its op tasks; attaches a telemetry
  # gate on it in init/2 and detaches it in finish/2.
  defmodule TickAdapter do
    @moduledoc false
    use AshQuint.Adapter

    alias AshQuint.Gate.Telemetry
    alias AshQuint.Step

    @impl true
    def init(_trace, opts) do
      test = Keyword.fetch!(opts, :test)
      id = Telemetry.attach([[:ash_quint_test, :tick]], name: :tick)
      send(test, {:init, Gate.current_replay(), id})
      {:ok, %{id: id, test: test}}
    end

    @impl true
    def step(ctx, %Step{action_taken: "IncStart", nondet_picks: %{"op" => op}}) do
      call = fn ->
        :telemetry.execute([:ash_quint_test, :tick], %{}, %{})
        :telemetry.execute([:ash_quint_test, :tick], %{}, %{})
        :ok
      end

      {:start, op, call, ctx, at: {:tick, 1}}
    end

    def step(ctx, %Step{action_taken: "IncRead", nondet_picks: %{"op" => op}}),
      do: {:advance, op, ctx, at: {:tick, 2}}

    def step(ctx, %Step{action_taken: "IncDone", nondet_picks: %{"op" => op}}),
      do: {:complete, op, ctx}

    @impl true
    def project(_ctx), do: %{}

    @impl true
    def finish(ctx, _result) do
      Telemetry.detach(ctx.id)
      send(ctx.test, :finished)
      :ok
    end
  end

  defp handlers(id), do: for(%{id: ^id} = handler <- :telemetry.list_handlers([]), do: handler)

  defp open, do: Ash.create!(RaceCounter, %{id: Ash.UUID.generate()}, action: :open)

  defp destroy_op(ref, id) do
    pid = Gate.start_op(ref, "o1", fn -> RaceCounter |> Ash.get!(id) |> Ash.destroy() end, [])
    %{"o1" => %{pid: pid, status: :running}}
  end

  describe "in a replay" do
    test "a telemetry gate stops the op at each event, named {name, n}" do
      states = [init(), inc_start(0, "o1", 1), inc_advance(0, "o1"), inc_done(0, "o1")]

      assert {:ok, _report} =
               Replay.run(TickAdapter, trace(states), adapter_opts: [test: self()])

      assert_received {:init, ref, id}
      assert is_reference(ref)
      assert {AshQuint.Gate.Telemetry, ^ref, _unique} = id
    end

    test "current_replay/0 is nil outside a replay" do
      assert Gate.current_replay() == nil

      states = [init(), inc_start(0, "o1", 1), inc_advance(0, "o1"), inc_done(0, "o1")]
      Replay.run(TickAdapter, trace(states), adapter_opts: [test: self()])

      assert Gate.current_replay() == nil
    end

    test "detach in finish/2 leaves no handlers" do
      states = [init(), inc_start(0, "o1", 1), inc_advance(0, "o1"), inc_done(0, "o1")]
      Replay.run(TickAdapter, trace(states), adapter_opts: [test: self()])

      assert_received {:init, _ref, id}
      assert_received :finished
      assert handlers(id) == []
    end
  end

  describe "Ash action spans" do
    test "an Ash action span gates" do
      %{id: id} = open()
      ref = make_ref()
      handler = Telemetry.attach([[:ash, :domain, :destroy, :start]], replay: ref, name: :destroy)
      on_exit(fn -> Telemetry.detach(handler) end)

      {ops, []} = Gate.await_settled(ref, destroy_op(ref, id), 1_000)
      assert {:gate, {:destroy, 1}, _pid, _reply} = ops["o1"].status
      assert %RaceCounter{} = Ash.get!(RaceCounter, id)

      {ops, []} = Gate.await_finished(ref, Gate.release(ops, "o1"), "o1", 1_000)
      assert {:finished, {:returned, :ok}} = ops["o1"].status
      assert {:error, _} = Ash.get(RaceCounter, id)
      Gate.cancel_all(ref, ops)
    end

    test "a handler attached by another replay doesn't gate this replay's ops" do
      %{id: id} = open()
      handler = Telemetry.attach([[:ash, :domain, :destroy, :start]], replay: make_ref())
      on_exit(fn -> Telemetry.detach(handler) end)
      ref = make_ref()

      {ops, []} = Gate.await_settled(ref, destroy_op(ref, id), 1_000)
      assert {:finished, {:returned, :ok}} = ops["o1"].status
      Gate.cancel_all(ref, ops)
    end

    test "outside an op task the handler does nothing" do
      %{id: id} = open()
      handler = Telemetry.attach([[:ash, :domain, :destroy, :start]], replay: make_ref())
      on_exit(fn -> Telemetry.detach(handler) end)

      assert :ok = RaceCounter |> Ash.get!(id) |> Ash.destroy()
      assert [_handler] = handlers(handler)
    end
  end

  describe "attach/2" do
    test "outside a replay, without replay:, raises" do
      assert_raise ArgumentError, ~r/replay/, fn -> Telemetry.attach([[:x]], []) end
    end

    test "a name fun gets the event, the metadata and n" do
      ref = make_ref()
      name = fn [:ash_quint_test, event], %{tag: tag}, n -> {event, tag, n} end
      handler = Telemetry.attach([[:ash_quint_test, :named]], replay: ref, name: name)
      on_exit(fn -> Telemetry.detach(handler) end)

      call = fn -> :telemetry.execute([:ash_quint_test, :named], %{}, %{tag: :a}) end
      pid = Gate.start_op(ref, "o1", call, [])

      {ops, []} = Gate.await_settled(ref, %{"o1" => %{pid: pid, status: :running}}, 1_000)
      assert {:gate, {:named, :a, 1}, _pid, _reply} = ops["o1"].status
      Gate.cancel_all(ref, ops)
    end

    test "a cancelled op exits from the handler, which stays attached" do
      ref = make_ref()
      handler = Telemetry.attach([[:ash_quint_test, :cancel]], replay: ref)
      on_exit(fn -> Telemetry.detach(handler) end)

      call = fn -> :telemetry.execute([:ash_quint_test, :cancel], %{}, %{}) end
      pid = Gate.start_op(ref, "o1", call, [])
      monitor = Process.monitor(pid)

      {ops, []} = Gate.await_settled(ref, %{"o1" => %{pid: pid, status: :running}}, 1_000)
      assert {:gate, {:query, 1}, _pid, _reply} = ops["o1"].status
      Gate.cancel_all(ref, ops)

      assert_received {:DOWN, ^monitor, :process, ^pid, {:shutdown, :ash_quint_cancelled}}
      assert [_handler] = handlers(handler)
    end
  end
end
