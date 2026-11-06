defmodule AshQuint.Case.AdapterCheck do
  @moduledoc false

  # Internal: AshQuint.Case's compile-time check of an adapter's step/2
  # clauses against the model interface. The clauses come from the
  # adapter's debug info (the expanded Elixir definitions); each clause's
  # second argument gives a literal action_taken and the literal keys of a
  # literal nondet_picks map, inside a %AshQuint.Step{} or a plain map
  # pattern. Anything else is :any.

  alias AshQuint.Interface

  @type clause :: %{action: String.t() | :any, picks: [String.t()] | :any}

  @doc """
  The adapter's `step/2` clauses, each with its literal action and picks
  (sorted), or `:any`. `:unavailable` when the module has no beam file, no
  Elixir debug info or no `step/2`.
  """
  @spec clauses(module()) :: {:ok, [clause()]} | :unavailable
  def clauses(module) do
    with path when is_list(path) and path != [] <- :code.which(module),
         {:ok, {^module, [debug_info: {:debug_info_v1, backend, data}]}} <-
           :beam_lib.chunks(path, [:debug_info]),
         {:ok, %{definitions: definitions}} <- debug_info(backend, module, data),
         {_name, _kind, _meta, clauses} <- List.keyfind(definitions, {:step, 2}, 0) do
      {:ok, Enum.map(clauses, &clause/1)}
    else
      _other -> :unavailable
    end
  end

  defp debug_info(backend, module, data) do
    backend.debug_info(:elixir_v1, module, data, [])
  rescue
    _error -> :error
  end

  defp clause({_meta, [_ctx, pattern], _guards, _body}), do: step_pattern(pattern)
  defp clause(_clause), do: %{action: :any, picks: :any}

  defp step_pattern(pattern) do
    case fields(pattern) do
      {:ok, fields} ->
        action = Keyword.get(fields, :action_taken)

        %{
          action: if(is_binary(action), do: action, else: :any),
          picks: picks(Keyword.fetch(fields, :nondet_picks))
        }

      :error ->
        %{action: :any, picks: :any}
    end
  end

  # The atom-keyed fields of a struct or map pattern, through `=` bindings.
  defp fields({:=, _meta, [left, right]}) do
    with :error <- fields(left), do: fields(right)
  end

  defp fields({:%, _meta, [_struct, map]}), do: fields(map)

  defp fields({:%{}, _meta, pairs}) when is_list(pairs) do
    {:ok, for({key, value} <- pairs, is_atom(key), do: {key, value})}
  end

  defp fields(_pattern), do: :error

  # No nondet_picks in the pattern: the clause matches no pick.
  defp picks(:error), do: []

  defp picks({:ok, {:=, _meta, [left, right]}}) do
    case picks({:ok, left}) do
      :any -> picks({:ok, right})
      picks -> picks
    end
  end

  defp picks({:ok, {:%{}, _meta, pairs}}) when is_list(pairs) do
    pairs |> Enum.flat_map(&pick_key/1) |> Enum.sort()
  end

  defp picks({:ok, _pattern}), do: :any

  defp pick_key({key, _value}) when is_binary(key), do: [key]
  defp pick_key(_pair), do: []

  @doc """
  The warnings for `adapter`'s `step/2` clauses against the interface of
  `model` (unknown actions, unknown picks and missing actions, never the
  init action); `[]` when the clauses are unavailable.
  """
  @spec warnings(module(), atom(), Interface.t(), String.t()) :: [String.t()]
  def warnings(adapter, model, %Interface{} = interface, init_action) do
    case clauses(adapter) do
      {:ok, clauses} -> build(inspect(adapter), model, interface.actions, init_action, clauses)
      :unavailable -> []
    end
  end

  defp build(name, model, actions, init_action, clauses) do
    by_name = Map.new(actions, &{&1.name, &1})
    listed = for action <- actions, action.name != init_action, do: action.name

    clause_warnings =
      Enum.flat_map(clauses, fn
        %{action: :any} ->
          []

        %{action: action, picks: picks} ->
          case Map.fetch(by_name, action) do
            {:ok, shape} ->
              pick_warnings(name, action, picks, shape)

            :error ->
              [
                "#{name} has a step/2 clause for #{inspect(action)}, which isn't an action of " <>
                  "#{inspect(model)} (actions: #{Enum.join(listed, ", ")})"
              ]
          end
      end)

    missing =
      if Enum.any?(clauses, &(&1.action == :any)) do
        []
      else
        covered = MapSet.new(clauses, & &1.action)

        for action <- listed, action not in covered do
          "#{name} has no step/2 clause for #{inspect(action)} of #{inspect(model)}"
        end
      end

    Enum.uniq(clause_warnings ++ missing)
  end

  defp pick_warnings(_name, _action, :any, _shape), do: []
  defp pick_warnings(_name, _action, _picks, %{picks: :map}), do: []

  defp pick_warnings(name, action, picks, shape) do
    known = known_picks(shape)
    listed = if known == [], do: "none", else: Enum.join(known, ", ")

    for pick <- picks, pick not in known do
      "#{name} step/2 clause for #{inspect(action)} matches pick #{inspect(pick)}, " <>
        "which #{action} doesn't have (picks: #{listed})"
    end
  end

  defp known_picks(%{picks: :record, fields: fields}), do: Enum.map(fields, & &1.name)
  defp known_picks(%{picks: :value}), do: ["value"]
  defp known_picks(%{picks: :unit}), do: []
end
