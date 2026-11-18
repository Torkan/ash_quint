defmodule AshQuint.Application do
  @moduledoc false
  # Starts the gate table (AshQuint.Gate.Table), which must exist before
  # and outlive any one test process. Where ash_quint isn't enabled
  # (AshQuint.enabled?/0), the supervisor starts nothing.

  use Application

  @children if AshQuint.enabled?(), do: [AshQuint.Gate.Table], else: []

  @impl true
  @spec start(Application.start_type(), term()) :: {:ok, pid()} | {:error, term()}
  def start(_type, _args) do
    Supervisor.start_link(@children,
      strategy: :one_for_one,
      name: AshQuint.Supervisor
    )
  end
end
