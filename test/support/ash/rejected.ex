defmodule AshQuint.Test.Rejected do
  @moduledoc false
  use Splode.Error, fields: [:code], class: :invalid

  @impl true
  def message(%{code: code}), do: "rejected: #{code}"
end
