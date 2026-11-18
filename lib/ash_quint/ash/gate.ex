# Compiled only when the optional `ash` dependency is present.
if Code.ensure_loaded?(Ash) do
  defmodule AshQuint.Ash.Gate do
    @moduledoc """
    An Ash change that puts a gate (`AshQuint.Gate.checkpoint/1`) in an
    action:

        change {AshQuint.Ash.Gate, at: :after_read}

    In an op task of a replay, the action stops at the gate `at:` until the
    replay releases it; anywhere else the change does nothing. Where
    ash_quint isn't enabled (`AshQuint.enabled?/0`), it adds no hook at
    all, so it can stay in the action in every environment.

    Where the action stops:

      * in an action that isn't atomic, in a `before_action` hook: after
        every change has run, inside the action's transaction, right before
        the data layer writes;
      * in an atomic action (`atomic/3`), while the changeset is built:
        before the transaction, before the data layer computes the atomic
        values from the row as it is when it writes.

    Only available when the project depends on `ash`. The action calls the
    change at run time, so ash_quint must be a dependency in every
    environment the resource runs in.

    ## Options

      * `:at` (required) — the gate's name, an atom. The adapter can name
        it in `{:advance, op, ctx, at: :after_read}`.
    """
    use Ash.Resource.Change

    @enabled AshQuint.enabled?()

    @impl true
    @spec init(keyword()) :: {:ok, keyword()} | {:error, String.t()}
    def init(opts) do
      case Keyword.fetch(opts, :at) do
        {:ok, at} when is_atom(at) and not is_nil(at) ->
          {:ok, opts}

        {:ok, at} ->
          {:error, "AshQuint.Ash.Gate: at: must be an atom, got #{inspect(at)}"}

        :error ->
          {:error, "AshQuint.Ash.Gate: at: is required, the gate's name"}
      end
    end

    @impl true
    @spec change(Ash.Changeset.t(), keyword(), Ash.Resource.Change.Context.t()) ::
            Ash.Changeset.t()
    if @enabled do
      def change(changeset, opts, _context) do
        at = Keyword.fetch!(opts, :at)

        Ash.Changeset.before_action(changeset, fn changeset ->
          AshQuint.Gate.checkpoint(at)
          changeset
        end)
      end
    else
      def change(changeset, _opts, _context), do: changeset
    end

    @impl true
    @spec atomic(Ash.Changeset.t(), keyword(), Ash.Resource.Change.Context.t()) ::
            {:ok, Ash.Changeset.t()}
    def atomic(changeset, opts, _context) do
      AshQuint.Gate.checkpoint(Keyword.fetch!(opts, :at))
      {:ok, changeset}
    end
  end
end
