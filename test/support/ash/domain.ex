defmodule AshQuint.Test.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshQuint.Test.Counter
    resource AshQuint.Test.RaceCounter
  end
end
