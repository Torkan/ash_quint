defmodule AshQuint.EnabledTest do
  # The disabled side (no gate table, no-op gates, replays that raise) needs
  # a build without the setting: scripts/check_disabled.exs, run in dev.
  use ExUnit.Case, async: true

  alias AshQuint.Gate.Table

  test "config/test.exs enables ash_quint" do
    assert AshQuint.enabled?()
  end

  test "ensure_enabled!/0 accepts an enabled build" do
    assert AshQuint.ensure_enabled!() == :ok
  end

  test "the application starts the gate table" do
    refute :ets.whereis(Table.name()) == :undefined
  end
end
