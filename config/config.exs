import Config

# The package's own test resources need this; a library's config isn't
# loaded by the projects that depend on it.
config :ash, default_string_length_count: :codepoints

if config_env() == :test do
  # Gates, replays and the gate table work only where this is set; in dev
  # (and in projects that don't set it) ash_quint is inert.
  config :ash_quint, enabled: true

  # Ash logs every action at :debug.
  config :logger, level: :warning

  # The :postgres-tagged tests' repo (test/support/test_repo.ex); started
  # only when they run. `mix test.create` and `mix test.migrate` set it up.
  config :ash_quint, AshQuint.TestRepo,
    username: "postgres",
    password: "postgres",
    hostname: "localhost",
    port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
    database: System.get_env("POSTGRES_TEST_DATABASE", "ash_quint_test"),
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 10,
    log: false

  config :ash_quint,
    ecto_repos: [AshQuint.TestRepo],
    ash_domains: [AshQuint.Test.PgDomain]
end
