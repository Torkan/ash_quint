defmodule AshQuint.TraceTest do
  use ExUnit.Case, async: true

  alias AshQuint.Trace

  @path "test/fixtures/itf/run.itf.json"

  test "Trace.load!/2 sets name, source and seed" do
    trace = Trace.load!(@path, name: "0", source: :random, seed: 1)

    assert %Trace{name: "0", source: :random, seed: 1, path: @path} = trace
    assert trace.states == AshQuint.ITF.read!(@path).states
    assert trace.vars == AshQuint.ITF.read!(@path).vars
  end

  test "label/1 names a trace or a manifest entry by source and name" do
    assert Trace.label(Trace.load!(@path, name: "0", source: :random, seed: 1)) == "random 0"
    assert Trace.label(%{source: :scenario, name: "incTest", file: "x"}) == "scenario incTest"
  end
end
