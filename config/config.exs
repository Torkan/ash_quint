import Config

# The package's own test resources need this; a library's config isn't
# loaded by the projects that depend on it.
config :ash, default_string_length_count: :codepoints

# Ash logs every action at :debug.
if config_env() == :test, do: config(:logger, level: :warning)
