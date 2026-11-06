# :quint_cli marks the tests that run real Quint (needs Node). It isn't
# :quint, which AshQuint.Case uses for its replay tests (quint: <source>).
# :postgres marks the tests that need Postgres; run them with
# `mix test --only postgres`, after `mix test.create` and `mix test.migrate`.
# :quint_explore marks the explore tests (AshQuint.Case's explore:); they
# run real Quint and fail unless started by `mix ash_quint.explore`.
ExUnit.start(exclude: [:quint_cli, :postgres, :quint_explore])

if Enum.any?(ExUnit.configuration()[:include], &(&1 == :postgres or match?({:postgres, _}, &1))) do
  {:ok, _pid} = AshQuint.TestRepo.start_link()
  Ecto.Adapters.SQL.Sandbox.mode(AshQuint.TestRepo, :manual)
end
