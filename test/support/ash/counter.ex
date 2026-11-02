defmodule AshQuint.Test.Counter do
  @moduledoc false
  use Ash.Resource,
    domain: AshQuint.Test.Domain,
    data_layer: Ash.DataLayer.Ets

  alias AshQuint.Test.Rejected

  ets do
    private? true
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, writable?: true, allow_nil?: false, public?: true
    attribute :count, :integer, default: 0, allow_nil?: false, public?: true
    attribute :writes, :integer, default: 0, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read]

    create :open do
      accept [:id]
    end

    update :inc do
      require_atomic? false
      argument :by, :integer, allow_nil?: false

      change fn changeset, _context ->
        count = Ash.Changeset.get_data(changeset, :count)
        by = Ash.Changeset.get_argument(changeset, :by)

        if count + by > 3 do
          Ash.Changeset.add_error(changeset, Rejected.exception(code: "over_limit"))
        else
          changeset
          |> Ash.Changeset.force_change_attribute(:count, count + by)
          |> bump_writes()
        end
      end
    end

    update :reset do
      require_atomic? false

      change fn changeset, _context ->
        if Ash.Changeset.get_data(changeset, :count) == 0 do
          Ash.Changeset.add_error(changeset, Rejected.exception(code: "already_zero"))
        else
          changeset
          |> Ash.Changeset.force_change_attribute(:count, 0)
          |> bump_writes()
        end
      end
    end
  end

  defp bump_writes(changeset) do
    writes = Ash.Changeset.get_data(changeset, :writes)
    Ash.Changeset.force_change_attribute(changeset, :writes, writes + 1)
  end
end
