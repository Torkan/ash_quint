defmodule AshQuint.TestRepo do
  @moduledoc false
  # The Postgres repo of the :postgres-tagged tests (config/config.exs). It is
  # started only when they run (test/test_helper.exs). Its migrations are
  # generated from the resources: `mix test.generate_migrations`.
  use AshPostgres.Repo, otp_app: :ash_quint

  @impl true
  def installed_extensions, do: ["ash-functions"]

  @impl true
  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
end
