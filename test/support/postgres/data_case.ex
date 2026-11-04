defmodule AshQuint.Test.DataCase do
  @moduledoc false
  # Tests against AshQuint.TestRepo, tagged :postgres (excluded from the
  # default suite; run them with `mix test --only postgres`).
  #
  #   use AshQuint.Test.DataCase, async: true   # shared sandbox connection
  #   use AshQuint.Test.DataCase, unboxed: true # real connections, async: false
  #
  # Sandboxed tests check out one connection, shared with every process (op
  # tasks included) through $callers. Unboxed tests switch the pool to :auto,
  # so each process checks out its own connection and commits for real; they
  # delete their own rows, and the pool is back in :manual mode afterwards.
  use ExUnit.CaseTemplate

  alias AshQuint.TestRepo
  alias Ecto.Adapters.SQL.Sandbox

  using opts do
    unboxed = Keyword.get(opts, :unboxed, false)

    if unboxed and Keyword.get(opts, :async, false),
      do: raise(ArgumentError, "unboxed tests commit for real, so they can't be async")

    quote do
      @moduletag :postgres
      @moduletag unboxed: unquote(unboxed)
      alias AshQuint.TestRepo
    end
  end

  setup tags do
    if tags[:unboxed] do
      :ok = Sandbox.mode(TestRepo, :auto)
      on_exit(fn -> Sandbox.mode(TestRepo, :manual) end)
    else
      pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])
      on_exit(fn -> Sandbox.stop_owner(pid) end)
    end

    :ok
  end
end
