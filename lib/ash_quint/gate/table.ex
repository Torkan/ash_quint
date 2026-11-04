defmodule AshQuint.Gate.Table do
  @moduledoc false
  # Owns the named, public ETS set that registers op tasks. A row is
  # {op_pid, replay_pid, replay_ref, op, mode, gate_timeout, info}, where
  # mode is :gated or :free and info is the map AshQuint.Gate.put_info/2
  # writes (the op task's own processes write it). The replay inserts a row before the op task runs its
  # call and deletes it when the op completes or is cancelled.

  use GenServer

  @table :ash_quint_gates

  @doc false
  @spec name() :: atom()
  def name, do: @table

  @doc false
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_arg), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  @spec init(nil) :: {:ok, nil}
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end
