defmodule AshQuint.Sandbox do
  @moduledoc false
  # The Ecto SQL sandbox for the replay's `sandbox:` option: a connection
  # of its own per replay, checked out before init/2 and checked in after
  # finish/2, so each trace runs in a transaction of its own and releases
  # its rows and locks when it ends. Ecto.Adapters.SQL.Sandbox is called
  # only when `sandbox:` is set; without ecto_sql, setting it raises.

  @typedoc "The repo (`nil`: no sandbox)."
  @type repo :: module() | nil

  @doc false
  # Checks out a connection for the calling process when it owns none and
  # isn't allowed on one. Returns the repo when this call checked one out
  # (to check it in later), `nil` otherwise.
  @spec checkout(repo()) :: repo()
  def checkout(nil), do: nil

  def checkout(repo) do
    case ecto_checkout(repo) do
      :ok -> repo
      {:already, _kind} -> nil
    end
  end

  @doc false
  @spec checkin(repo()) :: :ok
  def checkin(nil), do: :ok

  def checkin(repo) do
    ecto_checkin(repo)
    :ok
  end

  @doc false
  # `call`, run in an op task, allowed on the connection the calling
  # process checked out first. In :manual mode op tasks reach it through
  # `$callers` anyway; in shared mode they would reach the shared owner's.
  @spec allowing(repo(), (-> term())) :: (-> term())
  def allowing(nil, call), do: call

  def allowing(repo, call) do
    owner = self()

    fn ->
      ecto_allow(repo, owner, self())
      call.()
    end
  end

  @doc false
  # Raises ArgumentError when the calling process already has a connection
  # (as owner or allowed), so `what` (an explore or sensitivity test) would
  # run every replay in that one transaction; `tag` is the test's tag.
  @spec ensure_unowned!(repo(), String.t(), atom()) :: :ok
  def ensure_unowned!(nil, _what, _tag), do: :ok

  def ensure_unowned!(repo, what, tag) do
    case checkout(repo) do
      nil ->
        raise ArgumentError, """
        #{what} has sandbox: #{inspect(repo)}, but the test process already has a sandbox \
        connection, so every replay would run in that one transaction and keep its rows and \
        locks until the test ends. Make the case template skip the sandbox for tests tagged \
        #{inspect(tag)}, for instance with a first setup clause like

            defp setup_sandbox(%{#{tag}: _}), do: :ok

        (see the README's "Databases")\
        """

      ^repo ->
        checkin(repo)
    end
  end

  if Code.ensure_loaded?(Ecto.Adapters.SQL.Sandbox) do
    alias Ecto.Adapters.SQL.Sandbox, as: EctoSandbox

    defp ecto_checkout(repo), do: EctoSandbox.checkout(repo)
    defp ecto_checkin(repo), do: EctoSandbox.checkin(repo)
    defp ecto_allow(repo, owner, pid), do: EctoSandbox.allow(repo, owner, pid)
  else
    defp ecto_checkout(repo), do: no_ecto_sql!(repo)
    defp ecto_checkin(repo), do: no_ecto_sql!(repo)
    defp ecto_allow(repo, _owner, _pid), do: no_ecto_sql!(repo)

    @spec no_ecto_sql!(module()) :: no_return()
    defp no_ecto_sql!(repo) do
      raise ArgumentError,
            "sandbox: #{inspect(repo)} needs ecto_sql (Ecto.Adapters.SQL.Sandbox isn't loaded)"
    end
  end
end
