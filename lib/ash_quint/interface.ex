defmodule AshQuint.Interface do
  @moduledoc """
  A model's interface: its actions with their pick shapes, its result
  variants and its other variables, read from the JSON IR of
  `quint compile --target=json` and recorded in the manifest (format 3,
  see `AshQuint.Manifest`).

    * `actions` — the variants of the action variable (at the model's
      `action_path`), in declaration order, each with its pick shape,
      matching `AshQuint.Step`'s picks: `:unit` (no picks), `:record`
      (`fields`: name and type, in order), `:value` (one pick `"value"`,
      with `type`) or `:map` (a Quint `Map` value, whose entries are the
      picks, with `type`). The init action is included.
    * `results` — the variant names at the model's `result_path`, or `nil`
      when the model has no result variable.
    * `vars` — every other variable, with its type, in declaration order.

  Types are Quint text (`render_type/1`), for people: no code parses them.
  Names stay strings.

  The IR is Quint's internal format, not a documented API: `from_ir/2`
  reads only the modules' `var` declarations and the `types` table, and
  returns an error naming the Quint version when their shape differs.
  """

  defstruct actions: [], results: nil, vars: []

  @type picks ::
          %{name: String.t(), picks: :unit | :value | :map, type: String.t() | nil}
          | %{name: String.t(), picks: :record, fields: [%{name: String.t(), type: String.t()}]}

  @type t :: %__MODULE__{
          actions: [picks()],
          results: [String.t()] | nil,
          vars: [%{name: String.t(), type: String.t()}]
        }

  @picks %{"unit" => :unit, "record" => :record, "value" => :value, "map" => :map}

  defmodule IRError do
    @moduledoc false
    defexception [:message]
  end

  @doc """
  The interface of the model whose JSON IR is `ir` (decoded).

  Options: `:action_path` and `:result_path` (required), the model's
  paths; `:quint`, the Quint version, for error messages.

  Variables are the `var` declarations of every module in the IR (a tests
  module declares none: they are in the module it imports), their names
  stripped of `::` qualifiers and deduplicated; each one's type is its
  entry in the IR's `types` table. Returns an error when the action isn't
  a sum type, the action variable is missing, the result isn't a sum type
  or the IR's shape is unexpected.
  """
  @spec from_ir(map(),
          action_path: [String.t()],
          result_path: [String.t()],
          quint: String.t()
        ) :: {:ok, t()} | {:error, String.t()}
  def from_ir(ir, opts) do
    action_path = Keyword.fetch!(opts, :action_path)
    result_path = Keyword.fetch!(opts, :result_path)
    quint = Keyword.get(opts, :quint, "?")

    try do
      vars = vars!(ir)
      [action_root | _] = action_path
      [result_root | _] = result_path

      with {:ok, action_type} <- fetch_var(vars, action_root),
           {:ok, actions} <- variants(action_type, action_path, "action"),
           {:ok, results} <- results(vars, result_path) do
        {:ok,
         %__MODULE__{
           actions: Enum.map(actions, &action/1),
           results: results && Enum.map(results, &elem(&1, 0)),
           vars:
             for {name, type} <- vars, name not in [action_root, result_root] do
               %{name: name, type: render_type(type)}
             end
         }}
      end
    rescue
      error in IRError ->
        {:error,
         "could not read the model interface from Quint #{quint}'s JSON IR: " <> error.message}
    end
  end

  defp vars!(%{"modules" => modules} = ir) when is_list(modules) do
    types = Map.get(ir, "types")
    unless is_map(types), do: raise(IRError, "no types table")

    modules
    |> Enum.flat_map(fn
      %{"declarations" => decls} when is_list(decls) -> decls
      _module -> raise IRError, "a module without declarations"
    end)
    |> Enum.filter(&match?(%{"kind" => "var"}, &1))
    |> Enum.reduce([], fn
      %{"name" => name, "id" => id}, acc when is_binary(name) and is_integer(id) ->
        name = name |> String.split("::") |> List.last()

        if List.keymember?(acc, name, 0),
          do: acc,
          else: [{name, var_type!(types, id, name)} | acc]

      _decl, _acc ->
        raise IRError, "a variable without name or id"
    end)
    |> Enum.reverse()
  end

  defp vars!(_ir), do: raise(IRError, "no modules list")

  defp var_type!(types, id, name) do
    case Map.get(types, Integer.to_string(id)) do
      %{"type" => type} when is_map(type) -> type
      _other -> raise IRError, "no type for variable #{name}"
    end
  end

  defp fetch_var(vars, name) do
    case List.keyfind(vars, name, 0) do
      {^name, type} -> {:ok, type}
      nil -> {:error, "no variable #{name} in the model"}
    end
  end

  defp results(vars, [root | _] = path) do
    case fetch_var(vars, root) do
      {:ok, type} -> variants(type, path, "result")
      {:error, _reason} -> {:ok, nil}
    end
  end

  # Follows the path's record fields from the root's type, then reads the
  # sum's variants.
  defp variants(type, [_root | fields] = path, what) do
    at = Enum.join(path, ".")

    fields
    |> Enum.reduce_while({:ok, type}, fn field, {:ok, type} ->
      with %{"kind" => "rec"} <- type,
           {^field, type} <- List.keyfind(row!(type), field, 0) do
        {:cont, {:ok, type}}
      else
        _other -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, %{"kind" => "sum"} = sum} ->
        {:ok, row!(sum)}

      {:ok, other} ->
        {:error, "the #{what} at #{at} must be a sum type, got #{render_type(other)}"}

      :error ->
        {:error, "the #{what} at #{at} must be a sum type, got #{render_type(type)}"}
    end
  end

  defp row!(%{"fields" => %{"fields" => fields}}) when is_list(fields) do
    Enum.map(fields, fn
      %{"fieldName" => name, "fieldType" => type} when is_binary(name) and is_map(type) ->
        {name, type}

      _field ->
        raise IRError, "a malformed row field"
    end)
  end

  defp row!(_type), do: raise(IRError, "a type without fields")

  defp action({name, %{"kind" => "tup"} = type}) do
    case row!(type) do
      [] -> %{name: name, picks: :unit, type: nil}
      _elems -> %{name: name, picks: :value, type: render_type(type)}
    end
  end

  defp action({name, %{"kind" => "rec"} = type}) do
    fields = Enum.map(row!(type), fn {field, t} -> %{name: field, type: render_type(t)} end)
    %{name: name, picks: :record, fields: fields}
  end

  defp action({name, %{"kind" => "fun"} = type}),
    do: %{name: name, picks: :map, type: render_type(type)}

  defp action({name, type}), do: %{name: name, picks: :value, type: render_type(type)}

  @doc """
  Renders a type of Quint's JSON IR as Quint text: `int`, `str`, `bool`,
  `Set[T]`, `List[T]`, `A -> B`, `(A, B)`, `{ f: T, g: U }`, `A | B(T)`
  for a sum (a unit variant is its name alone), the name of a `const` or
  type variable, and `?` for any other kind.
  """
  @spec render_type(map()) :: String.t()
  def render_type(%{"kind" => kind}) when kind in ["int", "str", "bool"], do: kind
  def render_type(%{"kind" => "set", "elem" => elem}), do: "Set[#{render_type(elem)}]"
  def render_type(%{"kind" => "list", "elem" => elem}), do: "List[#{render_type(elem)}]"

  def render_type(%{"kind" => "fun", "arg" => arg, "res" => res}),
    do: "#{render_type(arg)} -> #{render_type(res)}"

  def render_type(%{"kind" => kind, "name" => name}) when kind in ["const", "var"], do: name

  def render_type(%{"kind" => kind, "fields" => %{"fields" => fields}} = type)
      when kind in ["tup", "rec", "sum"] and is_list(fields) do
    render_fields(kind, row!(type))
  rescue
    IRError -> "?"
  end

  def render_type(_type), do: "?"

  defp render_fields("tup", elems),
    do: "(" <> Enum.map_join(elems, ", ", fn {_n, t} -> render_type(t) end) <> ")"

  defp render_fields("rec", fields),
    do: "{ " <> Enum.map_join(fields, ", ", fn {n, t} -> "#{n}: #{render_type(t)}" end) <> " }"

  defp render_fields("sum", variants) do
    Enum.map_join(variants, " | ", fn {name, type} ->
      if unit?(type), do: name, else: "#{name}(#{render_type(type)})"
    end)
  end

  defp unit?(%{"kind" => "tup", "fields" => %{"fields" => []}}), do: true
  defp unit?(_type), do: false

  @doc """
  The interface as manifest JSON: `actions`, `results` and `vars`, keys
  sorted at every level, lists in order. An action has `name`, `picks`
  and `type` (`value` and `map`) or `fields` (`record`).
  """
  @spec to_json(t()) :: Jason.OrderedObject.t()
  def to_json(%__MODULE__{} = interface) do
    ordered(%{
      "actions" => Enum.map(interface.actions, &action_json/1),
      "results" => interface.results,
      "vars" => Enum.map(interface.vars, &ordered(%{"name" => &1.name, "type" => &1.type}))
    })
  end

  defp action_json(%{picks: :record} = action) do
    fields = Enum.map(action.fields, &ordered(%{"name" => &1.name, "type" => &1.type}))
    ordered(%{"name" => action.name, "picks" => "record", "fields" => fields})
  end

  defp action_json(%{picks: :unit} = action),
    do: ordered(%{"name" => action.name, "picks" => "unit"})

  defp action_json(action),
    do:
      ordered(%{
        "name" => action.name,
        "picks" => Atom.to_string(action.picks),
        "type" => action.type
      })

  defp ordered(map),
    do: map |> Enum.sort_by(fn {key, _value} -> key end) |> Jason.OrderedObject.new()

  @doc """
  Reads an interface from decoded manifest JSON. `path` is used in error
  messages: raises `ArgumentError` (`"<path>: invalid manifest:
  interface…"`) for a malformed interface.
  """
  @spec from_json!(term(), String.t()) :: t()
  def from_json!(json, path) when is_map(json) do
    actions = Map.get(json, "actions")
    results = Map.get(json, "results")
    vars = Map.get(json, "vars")

    unless is_list(actions), do: fail!(path, "interface.actions must be a list")

    unless is_nil(results) or (is_list(results) and Enum.all?(results, &is_binary/1)),
      do: fail!(path, "interface.results must be null or a list of strings")

    unless is_list(vars) and Enum.all?(vars, &name_and_type?/1),
      do: fail!(path, "interface.vars must be a list of name and type")

    %__MODULE__{
      actions: actions |> Enum.with_index() |> Enum.map(&action_from_json!(&1, path)),
      results: results,
      vars: Enum.map(vars, &%{name: &1["name"], type: &1["type"]})
    }
  end

  def from_json!(_json, path), do: fail!(path, "interface must be an object")

  defp action_from_json!({%{"name" => name, "picks" => picks} = json, index}, path)
       when is_binary(name) do
    case {Map.fetch(@picks, picks), json} do
      {:error, _json} ->
        fail!(
          path,
          "interface.actions[#{index}].picks must be one of map, record, unit, value"
        )

      {{:ok, :unit}, _json} ->
        %{name: name, picks: :unit, type: nil}

      {{:ok, :record}, %{"fields" => fields}} when is_list(fields) ->
        if Enum.all?(fields, &name_and_type?/1),
          do: %{
            name: name,
            picks: :record,
            fields: Enum.map(fields, &%{name: &1["name"], type: &1["type"]})
          },
          else: malformed!(path, index)

      {{:ok, shape}, %{"type" => type}} when shape in [:value, :map] and is_binary(type) ->
        %{name: name, picks: shape, type: type}

      _other ->
        malformed!(path, index)
    end
  end

  defp action_from_json!({_json, index}, path), do: malformed!(path, index)

  @spec malformed!(String.t(), non_neg_integer()) :: no_return()
  defp malformed!(path, index), do: fail!(path, "interface.actions[#{index}] is malformed")

  defp name_and_type?(%{"name" => name, "type" => type}) when is_binary(name) and is_binary(type),
    do: true

  defp name_and_type?(_value), do: false

  defp fail!(path, reason), do: raise(ArgumentError, "#{path}: invalid manifest: #{reason}")
end
