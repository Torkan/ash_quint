defmodule AshQuint.Test.PgRaceCounter do
  @moduledoc false
  # AshQuint.Test.RaceCounter over Postgres (table race_counters), for the
  # race example's unboxed replays and the sandbox tests. Rows are scoped
  # by id; the adapters delete their own.
  #
  #   :inc         a read-modify-write: count + by is computed from the
  #                changeset's data (the row as read), then the op is gated
  #                at :after_read (in a before_action, inside the action's
  #                transaction), then the sum is written. Two incs that both
  #                read before either writes lose an update.
  #   :inc_atomic  gated at :requested, then count + by is computed by
  #                Postgres from the row as it is when written, and the
  #                limit is checked there too.
  #
  # Both bump `writes` atomically, so a lost update still counts two writes.
  use Ash.Resource,
    domain: AshQuint.Test.PgDomain,
    data_layer: AshPostgres.DataLayer

  require Ash.Expr

  alias AshQuint.Test.Rejected

  @limit 3

  postgres do
    table "race_counters"
    repo AshQuint.TestRepo
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, writable?: true, allow_nil?: false, public?: true
    attribute :count, :integer, default: 0, allow_nil?: false, public?: true
    attribute :writes, :integer, default: 0, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read, :destroy]

    create :open do
      accept [:id]
    end

    update :inc do
      require_atomic? false
      argument :by, :integer, allow_nil?: false

      change fn changeset, _context ->
        count = Ash.Changeset.get_data(changeset, :count)
        by = Ash.Changeset.get_argument(changeset, :by)

        if count + by > @limit do
          Ash.Changeset.add_error(changeset, Rejected.exception(code: "over_limit"))
        else
          Ash.Changeset.force_change_attribute(changeset, :count, count + by)
        end
      end

      change {AshQuint.Ash.Gate, at: :after_read}
      change atomic_update(:writes, expr(writes + 1))
    end

    update :inc_atomic do
      argument :by, :integer, allow_nil?: false

      change {AshQuint.Ash.Gate, at: :requested}

      change atomic_update(
               :count,
               expr(
                 if count + ^arg(:by) > ^@limit do
                   error(AshQuint.Test.Rejected, %{code: "over_limit"})
                 else
                   count + ^arg(:by)
                 end
               )
             )

      change atomic_update(:writes, expr(writes + 1))
    end
  end
end
