defmodule AshQuint.AshTest do
  use ExUnit.Case, async: true

  require Ash.Query

  alias Ash.Error.Invalid
  alias AshQuint.Test.{Counter, Rejected}

  defmodule StubRepo do
    @moduledoc false
    def query!(sql, params) do
      send(self(), {:query, sql, params})
      %{columns: ["id", "n"], rows: [[1, 2]]}
    end
  end

  defp open do
    id = Ash.UUID.generate()
    {:ok, counter} = Ash.create(Counter, %{id: id}, action: :open)
    counter
  end

  defp inc(counter, by), do: Ash.update(counter, %{by: by}, action: :inc)

  describe "outcome/2" do
    test "accepted" do
      result = Ash.create(Counter, %{id: Ash.UUID.generate()}, action: :open)
      assert AshQuint.Ash.outcome(result) == :accepted
    end

    test ":ok is accepted" do
      assert AshQuint.Ash.outcome(:ok) == :accepted
    end

    test "mapped rejection by function" do
      result = inc(open(), 4)

      assert AshQuint.Ash.outcome(result, codes: %{Rejected => & &1.code}) ==
               {:rejected, "over_limit"}
    end

    test "mapped rejection by string" do
      result = inc(open(), 4)
      assert AshQuint.Ash.outcome(result, codes: %{Rejected => "nope"}) == {:rejected, "nope"}
    end

    test "a nested Invalid is unwrapped once" do
      inner = Invalid.exception(errors: [Rejected.exception(code: "over_limit")])
      outer = Invalid.exception(errors: [inner])

      assert AshQuint.Ash.outcome({:error, outer}, codes: %{Rejected => & &1.code}) ==
               {:rejected, "over_limit"}
    end

    test "unmapped error fails with its message" do
      assert {:failed, msg} = AshQuint.Ash.outcome(inc(open(), 4))
      assert msg =~ "rejected: over_limit"
    end

    test "a mapped error among several fails" do
      error =
        Invalid.exception(errors: [Rejected.exception(code: "a"), Rejected.exception(code: "b")])

      assert {:failed, msg} = AshQuint.Ash.outcome({:error, error}, codes: %{Rejected => "x"})
      assert msg =~ "rejected: a"
      assert msg =~ "rejected: b"
    end

    test "non-exception errors fail with their inspect" do
      assert AshQuint.Ash.outcome({:error, :nope}) == {:failed, ":nope"}
    end

    test "non-result values fail" do
      assert AshQuint.Ash.outcome(:boom) == {:failed, ":boom"}
    end
  end

  describe "read_map/2" do
    test "read_map keys rows by the key field" do
      %{id: id1} = c1 = open()
      %{id: id2} = open()
      {:ok, _} = inc(c1, 1)

      assert AshQuint.Ash.read_map(Counter, key: :id, fields: [:count, :writes]) == %{
               id1 => %{count: 1, writes: 1},
               id2 => %{count: 0, writes: 0}
             }
    end

    test "read_map takes a query" do
      %{id: id1} = c1 = open()
      open()
      {:ok, _} = inc(c1, 1)

      assert AshQuint.Ash.read_map(Ash.Query.filter(Counter, id == ^id1),
               key: :id,
               fields: [:count],
               read_opts: [authorize?: false]
             ) == %{id1 => %{count: 1}}
    end

    test "read_map refuses an unknown field" do
      open()

      assert_raise KeyError, ~r/key :nope not found/, fn ->
        AshQuint.Ash.read_map(Counter, key: :id, fields: [:nope])
      end
    end
  end

  describe "sql_rows/3" do
    test "sql_rows zips columns and rows" do
      assert AshQuint.Ash.sql_rows(StubRepo, "select id, n from t where id = $1", [1]) ==
               [%{"id" => 1, "n" => 2}]

      assert_received {:query, "select id, n from t where id = $1", [1]}
    end

    test "params default to []" do
      assert AshQuint.Ash.sql_rows(StubRepo, "select 1") == [%{"id" => 1, "n" => 2}]
      assert_received {:query, "select 1", []}
    end
  end
end
