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
  end
end
