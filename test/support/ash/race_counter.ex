defmodule AshQuint.Test.RaceCounter do
  @moduledoc false
  # The race example's resource. Its ETS table isn't private, so op tasks
  # (other processes) see the rows; adapters scope by row id.
  #
  #   :inc         a read-modify-write: count + by is computed from the
  #                changeset's data (the row as read), then the op is gated
  #                at :after_read (AshQuint.Ash.Gate, in a before_action),
  #                then the sum is written. Two incs that both read before
  #                either writes lose an update.
  #   :inc_atomic  gated at :requested (AshQuint.Ash.Gate, atomic/3), then
  #                count + by is computed by the data layer from the row as
  #                it is when written, and the limit is checked there too.
  #
  # Both bump `writes` atomically, so a lost update still counts two writes.
  use Ash.Resource,
    domain: AshQuint.Test.Domain,
    data_layer: Ash.DataLayer.Ets

  require Ash.Expr

  alias AshQuint.Test.Rejected

  @limit 3

  ets do
    private? false
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
