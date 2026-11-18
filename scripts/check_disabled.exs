# Checks that ash_quint is inert where it isn't enabled (the default): no gate
# table, gates that never consult one, and replays that refuse to run. Run it in
# a build without `config :ash_quint, enabled: true`, such as this repo's dev
# env:
#
#     MIX_ENV=dev mix run scripts/check_disabled.exs
#
# CI also runs it in a project that depends on ash_quint without Ash, where the
# Ash and telemetry checks are skipped.
ExUnit.start(autorun: true)

defmodule AshQuint.CheckDisabled do
  use ExUnit.Case

  @disabled "ash_quint is disabled in this environment: add `config :ash_quint, enabled: true` to config/test.exs"

  # A gate table with a gated row for the calling process: enabled, a gate
  # here would report to the "replay" (this process) and wait.
  defp gated_row do
    ref = make_ref()
    :ets.new(:ash_quint_gates, [:named_table, :public, :set])
    :ets.insert(:ash_quint_gates, {self(), self(), ref, "o1", :gated, 50, %{}})
    ref
  end

  test "ash_quint isn't enabled" do
    refute AshQuint.enabled?()
  end

  test "the application starts no gate table" do
    assert :ets.whereis(:ash_quint_gates) == :undefined
  end

  test "checkpoint/1 doesn't consult the gate table" do
    ref = gated_row()
    assert AshQuint.Gate.checkpoint(:after_read) == :ok
    refute_received {:ash_quint_gate, ^ref, _op, _name, _pid, _reply}
  end

  test "put_info/2 doesn't write the gate table" do
    ref = gated_row()
    assert AshQuint.Gate.put_info(:backend_pid, 1) == :ok
    assert :ets.lookup(:ash_quint_gates, self()) == [{self(), self(), ref, "o1", :gated, 50, %{}}]
  end

  test "a replay raises" do
    trace = %AshQuint.Trace{path: nil, vars: ["lastAction"], states: [%{"lastAction" => "Init"}]}
    assert_raise RuntimeError, @disabled, fn -> AshQuint.Replay.run(:no_adapter, trace) end
  end

  if Code.ensure_loaded?(AshQuint.Gate.Telemetry) do
    test "attaching telemetry gates raises" do
      assert_raise RuntimeError, @disabled, fn ->
        AshQuint.Gate.Telemetry.attach([[:my_app, :repo, :query]], replay: make_ref())
      end
    end
  end

  if Code.ensure_loaded?(AshQuint.Ash.Gate) do
    test "the Ash change adds no hook" do
      changeset = %Ash.Changeset{}
      assert AshQuint.Ash.Gate.change(changeset, [at: :after_read], %{}) == changeset
    end

    test "the Ash change's atomic/3 doesn't gate" do
      ref = gated_row()
      changeset = %Ash.Changeset{}
      assert AshQuint.Ash.Gate.atomic(changeset, [at: :after_read], %{}) == {:ok, changeset}
      refute_received {:ash_quint_gate, ^ref, _op, _name, _pid, _reply}
    end
  end
end
