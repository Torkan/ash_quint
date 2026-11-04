defmodule AshQuint.AshTracerTest do
  # Sets the global :ash :tracer config, so it isn't async.
  use ExUnit.Case, async: false

  alias AshQuint.Gate
  alias AshQuint.Test.Tracer

  setup do
    previous = Application.fetch_env(:ash, :tracer)
    Application.put_env(:ash, :tracer, [Tracer])

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ash, :tracer, value)
        :error -> Application.delete_env(:ash, :tracer)
      end
    end)
  end

  test "transfer_context/1 returns a fun that sets the caller's span contexts" do
    Process.put(:test_span, :outer)
    transfer = AshQuint.Ash.transfer_context(tracer: Tracer)

    task =
      Task.async(fn ->
        before = Process.get(:test_span)
        :ok = transfer.()
        {before, Process.get(:test_span)}
      end)

    assert Task.await(task) == {nil, :outer}
  end

  test "an op task sees the test process's tracer span context" do
    Process.put(:test_span, {:span, 42})
    ref = make_ref()
    pid = Gate.start_op(ref, "o1", fn -> Process.get(:test_span) end, [])

    {ops, []} = Gate.await_finished(ref, %{"o1" => %{pid: pid, status: :running}}, "o1", 1_000)
    assert ops["o1"].status == {:finished, {:returned, {:span, 42}}}
    Gate.cancel_all(ref, ops)
  end
end
