defmodule AshQuint.Test.PgDomain do
  @moduledoc false
  # The resources over AshQuint.TestRepo (config :ash_quint, ash_domains).
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshQuint.Test.PgRaceCounter
  end
end
