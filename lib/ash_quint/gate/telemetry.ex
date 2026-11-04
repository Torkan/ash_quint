# Compiled only when the optional `telemetry` dependency is present.
if Code.ensure_loaded?(:telemetry) do
  defmodule AshQuint.Gate.Telemetry do
    @moduledoc """
    Telemetry gates: a gate (`AshQuint.Gate.checkpoint/1`) at every
    telemetry event an op task emits, without changing the system's code.

    An adapter attaches them in `init/2` and detaches them in `finish/2`:

        def init(trace, opts) do
          gates = AshQuint.Gate.Telemetry.attach([[:my_app, :repo, :query]])
          {:ok, %{gates: gates}}
        end

        def finish(ctx, _result) do
          AshQuint.Gate.Telemetry.detach(ctx.gates)
          :ok
        end

    Telemetry handlers run in the process that emits the event, so a
    handler on Ecto's `[…, :repo, :query]` stops an op task after each of
    its SQL statements, and one on an Ash action span (`[:ash, domain,
    :update, :start]`, say) stops it as the action starts. The gates are
    named `{:query, 1}`, `{:query, 2}`, … by default, counted per process,
    so the adapter can name the gate it expects:
    `{:advance, op, ctx, at: {:query, 2}}`.

    Telemetry handlers are global, but these gates are scoped: a handler
    gates only the op tasks of the replay that attached it (and the
    processes they start), so other tests, and other replays running at the
    same time, pass at once. The cost of a gate counted by events: the gate
    comes after the query, not before it, and the count changes when the
    query plan does.

    Only available when the project depends on `telemetry` (Ash and Ecto
    do).
    """

    alias AshQuint.Gate

    @typedoc "The handler id `attach/2` returns."
    @type handler_id :: {module(), reference(), reference()}

    @typedoc "A gate's name, or a function of the event, its metadata and the count."
    @type name ::
            atom()
            | ([atom()], map(), pos_integer() -> Gate.name())

    @typedoc "Options of `attach/2`."
    @type option :: {:replay, reference()} | {:name, name()}

    @doc """
    Attaches a gate to each of `events` (telemetry event names) for the ops
    of the current replay, and returns the handler id for `detach/1`.

    Call it from the adapter's `init/2`, where the replay is
    `AshQuint.Gate.current_replay/0`.

    ## Options

      * `:name` — an atom `name`, which names the `n`th gate of a process
        `{name, n}`, or a function `(event, metadata, n -> gate_name)`.
        Default `:query`.
      * `:replay` — the replay whose ops are gated. Default
        `AshQuint.Gate.current_replay/0`; raises `ArgumentError` when there
        is none.
    """
    @spec attach([[atom()]], [option()]) :: handler_id()
    def attach(events, opts \\ []) do
      ref =
        Keyword.get_lazy(opts, :replay, &Gate.current_replay/0) ||
          raise ArgumentError,
                "AshQuint.Gate.Telemetry.attach/2 needs a replay: call it from the " <>
                  "adapter's init/2, or pass replay: ref"

      id = {__MODULE__, ref, make_ref()}
      config = %{id: id, replay: ref, name: Keyword.get(opts, :name, :query)}
      :ok = :telemetry.attach_many(id, events, &__MODULE__.handle/4, config)
      id
    end

    @doc """
    Detaches the gates `attach/2` attached. Returns `:ok`, also when they
    are already detached.
    """
    @spec detach(handler_id()) :: :ok
    def detach(id) do
      _ = :telemetry.detach(id)
      :ok
    end

    @doc false
    # The telemetry handler. It never raises: telemetry detaches a handler
    # that does. A cancelled op exits with an exit signal to itself instead,
    # since telemetry would catch an exit too.
    @spec handle([atom()], map(), map(), map()) :: :ok
    def handle(event, _measurements, metadata, %{id: id, replay: ref, name: name}) do
      if Gate.current_op(ref) do
        n = Process.get({__MODULE__, id}, 0) + 1
        Process.put({__MODULE__, id}, n)

        case Gate.scoped_checkpoint(ref, gate_name(name, event, metadata, n)) do
          :ok -> :ok
          :cancel -> cancelled()
        end
      end

      :ok
    catch
      _kind, _reason -> :ok
    end

    defp gate_name(name, _event, _metadata, n) when is_atom(name), do: {name, n}

    defp gate_name(name, event, metadata, n) when is_function(name, 3),
      do: name.(event, metadata, n)

    @spec cancelled() :: no_return()
    defp cancelled do
      Process.exit(self(), {:shutdown, :ash_quint_cancelled})

      # The exit signal is handled at the latest when the process waits.
      receive do
      after
        :infinity -> :ok
      end
    end
  end
end
