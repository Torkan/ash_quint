defmodule AshQuint.Application do
  @moduledoc false
  # Starts the gate table (AshQuint.Gate.Table), which must exist before
  # and outlive any one test process.

  use Application

  @impl true
  @spec start(Application.start_type(), term()) :: {:ok, pid()} | {:error, term()}
  def start(_type, _args) do
    Supervisor.start_link([AshQuint.Gate.Table],
      strategy: :one_for_one,
      name: AshQuint.Supervisor
    )
  end
end
