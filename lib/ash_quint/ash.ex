# Compiled only when the optional `ash` dependency is present, so the rest of
# ash_quint builds and runs without it.
if Code.ensure_loaded?(Ash) do
  defmodule AshQuint.Ash do
    @moduledoc """
    Helpers for adapters over Ash resources.

    Only available when the project depends on `ash`.

      * `outcome/2` classifies an Ash action result as the model's
        `Accepted` or `Rejected(code)`, or as a failure.
      * `read_map/2` snapshots a resource as a map keyed by one field.
      * `sql_rows/3` snapshots raw SQL rows, for state that Ash doesn't read
        one row per record (temporal versions, for example).
      * `pg_backend_pid/1` and `pg_blocked?/2` tell the replay that an op
        waits on a Postgres lock (for `c:AshQuint.Adapter.blocked?/2`).
      * `transfer_context/1` carries the tracer span context into an op
        task; the replay calls it.
    """

    @type outcome :: :accepted | {:rejected, String.t()} | {:failed, String.t()}

    @type code :: String.t() | (Exception.t() -> String.t())

    @type outcome_option :: {:codes, %{optional(module()) => code()}}

    @type read_map_option ::
            {:key, atom()} | {:fields, [atom()]} | {:read_opts, Keyword.t()}

    @doc """
    Classifies the result of an Ash action.

      * `{:ok, _}` and `:ok` are `:accepted`.
      * `{:error, %Ash.Error.Invalid{errors: [e]}}` is `{:rejected, code}`
        when `e`'s module is a key of `codes:`. The code is the mapped
        string, or the mapped function applied to `e`. An `Ash.Error.Invalid`
        whose only error is another `Ash.Error.Invalid` is unwrapped once
        first.
      * Any other `{:error, error}` is `{:failed, Exception.message(error)}`
        (`inspect/1` when `error` isn't an exception), and any other value is
        `{:failed, inspect(value)}`.

    ## Options

      * `:codes` — `%{module() => String.t() | (Exception.t() -> String.t())}`,
        the error modules that are model rejections. Default `%{}`.

    ## Example

        AshQuint.Ash.outcome(result, codes: %{MyApp.Rejected => & &1.code})
    """
    @spec outcome(term(), [outcome_option()]) :: outcome()
    def outcome(result, opts \\ [])

    def outcome({:error, %Ash.Error.Invalid{errors: [%Ash.Error.Invalid{} = inner]}}, opts),
      do: classify_error(inner, Keyword.get(opts, :codes, %{}))

    def outcome(result, opts), do: classify(result, Keyword.get(opts, :codes, %{}))

    defp classify(:ok, _codes), do: :accepted
    defp classify({:ok, _}, _codes), do: :accepted
    defp classify({:error, error}, codes), do: classify_error(error, codes)
    defp classify(other, _codes), do: {:failed, inspect(other)}

    defp classify_error(%Ash.Error.Invalid{errors: [%mod{} = error]} = invalid, codes) do
      case Map.fetch(codes, mod) do
        {:ok, code} when is_binary(code) -> {:rejected, code}
        {:ok, fun} when is_function(fun, 1) -> {:rejected, fun.(error)}
        :error -> {:failed, Exception.message(invalid)}
      end
    end

    defp classify_error(error, _codes) when is_exception(error),
      do: {:failed, Exception.message(error)}

    defp classify_error(error, _codes), do: {:failed, inspect(error)}

    @doc """
    Reads a resource (or an `Ash.Query`) with `Ash.read!/2` and returns its
    records as a map from each record's `key:` value to a map of its
    `fields:`.

    ## Options

      * `:key` (required) — the field whose value keys the map.
      * `:fields` (required) — the fields in each value map; a field the
        record doesn't have raises `KeyError`.
      * `:read_opts` — passed to `Ash.read!/2`, for example
        `[tenant: t, authorize?: false]`. Default `[]`.

    ## Example

        AshQuint.Ash.read_map(MyApp.Account, key: :id, fields: [:plan, :state])
        #=> %{id => %{plan: ..., state: ...}}
    """
    @spec read_map(Ash.Resource.t() | Ash.Query.t(), [read_map_option()]) ::
            %{optional(term()) => %{optional(atom()) => term()}}
    def read_map(resource_or_query, opts) do
      key = Keyword.fetch!(opts, :key)
      fields = Keyword.fetch!(opts, :fields)

      resource_or_query
      |> Ash.read!(Keyword.get(opts, :read_opts, []))
      |> Map.new(fn record ->
        {Map.fetch!(record, key), Map.new(fields, &{&1, Map.fetch!(record, &1)})}
      end)
    end

    @doc """
    Runs `sql` with `params` through `repo.query!/2` and returns the rows as
    maps from column name to value.

    `repo` is any module whose `query!/2` returns a map with `:columns` and
    `:rows`, such as an `Ecto.Repo` over Postgres.

    ## Example

        AshQuint.Ash.sql_rows(MyApp.Repo, "select id, plan from versions where id = $1", [id])
        #=> [%{"id" => id, "plan" => "pro"}]
    """
    @spec sql_rows(module(), String.t(), list()) :: [%{optional(String.t()) => term()}]
    def sql_rows(repo, sql, params \\ []) do
      %{columns: columns, rows: rows} = repo.query!(sql, params)
      Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
    end

    @doc """
    Returns the Postgres backend pid of the connection `repo` uses in the
    calling process, and records it as the op's `:backend_pid` with
    `AshQuint.Gate.put_info/2` (in an op task; elsewhere it only returns
    it).

    Call it inside the op's call, on the connection the call's statements
    use: inside its transaction, or with a pool that keeps one connection
    per process (the Ecto sandbox in `:auto` mode does). Then the adapter's
    `blocked?/2` can ask `pg_blocked?/2` whether the op waits on a lock.

    ## Example

        call = fn ->
          MyApp.Repo.transaction(fn ->
            AshQuint.Ash.pg_backend_pid(MyApp.Repo)
            # the statements that may wait on another op's row lock
          end)
        end
    """
    @spec pg_backend_pid(module()) :: integer()
    def pg_backend_pid(repo) do
      %{rows: [[pid]]} = repo.query!("select pg_backend_pid()", [])
      AshQuint.Gate.put_info(:backend_pid, pid)
      pid
    end

    @doc """
    Whether the Postgres backend `backend` is waiting on a lock that another
    backend holds (`pg_blocking_pids/1` isn't empty).

    `backend` is a backend pid, an op's info (a map with `:backend_pid`) or
    the `t:AshQuint.Adapter.op_info/0` that `blocked?/2` is given. An op
    that recorded no backend pid (see `pg_backend_pid/1`) is not blocked.

    It runs a query on `repo` from the calling process, so that process
    needs a connection of its own: in the Ecto sandbox's shared mode the
    query would wait for the connection the op holds.

    ## Example

        @impl true
        def blocked?(_ctx, op_info), do: AshQuint.Ash.pg_blocked?(MyApp.Repo, op_info)
    """
    @spec pg_blocked?(module(), integer() | map()) :: boolean()
    def pg_blocked?(repo, %{info: info}) when is_map(info), do: pg_blocked?(repo, info)
    def pg_blocked?(repo, %{backend_pid: backend}), do: pg_blocked?(repo, backend)

    def pg_blocked?(repo, backend) when is_integer(backend) do
      %{rows: [[blocked]]} =
        repo.query!("select cardinality(pg_blocking_pids($1)) > 0", [backend])

      blocked
    end

    def pg_blocked?(_repo, _info), do: false

    @doc """
    Captures the calling process's Ash tracer span contexts and returns a
    function that sets them in the process that calls it.

    `AshQuint.Replay` calls it when it starts an op task, and runs the
    function in the task before the op's call, so spans the call opens are
    children of the test's spans. Only tracer context moves between
    processes this way: actor and tenant travel in the call's options.

    ## Options

      * `:tracer` — a tracer module or a list of them. Default: the
        `:tracer` configured for `:ash`.
    """
    @spec transfer_context([{:tracer, module() | [module()] | nil}]) :: (-> :ok)
    def transfer_context(opts \\ []) do
      tracers = Keyword.get_lazy(opts, :tracer, fn -> Application.get_env(:ash, :tracer) end)
      context = Ash.ProcessHelpers.get_context_for_transfer(tracer: tracers)
      fn -> Ash.ProcessHelpers.transfer_context(context) end
    end
  end
end
