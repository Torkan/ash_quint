defmodule AshQuint.Postgres.SandboxHelpers do
  @moduledoc false
  # Raw SQL on race_counters, through AshQuint.TestRepo.

  alias AshQuint.TestRepo

  def open do
    id = Ecto.UUID.generate()
    TestRepo.query!("insert into race_counters (id) values ($1)", [dump(id)])
    id
  end

  def count(id) do
    %{rows: [[count]]} =
      TestRepo.query!("select count from race_counters where id = $1", [dump(id)])

    count
  end

  def set(id, count),
    do: TestRepo.query!("update race_counters set count = $2 where id = $1", [dump(id), count])

  def delete(id), do: TestRepo.query!("delete from race_counters where id = $1", [dump(id)])

  def dump(id), do: Ecto.UUID.dump!(id)
end
