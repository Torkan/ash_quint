defmodule AshQuint.Postgres.RepoTest do
  use AshQuint.Test.DataCase, async: true

  test "the repo answers select 1" do
    assert %{rows: [[1]]} = TestRepo.query!("select 1")
  end
end
