defmodule AshQuint.ITF do
  @moduledoc """
  Decodes Quint ITF (Informal Trace Format) JSON into `AshQuint.Trace`.

  Values decode as follows:

    * `{"#bigint": "42"}` → `42`
    * `{"s": …, "e": …, "c": […]}`, the bignumber.js object Quint 0.33
      writes instead of `#bigint` for integers with |n| ≥ 10^15 → that integer
      (only a record with exactly these fields, consistent with that layout)
    * `{"#map": [[k, v], …]}` → a map
    * `{"#set": […]}` → a `MapSet`
    * `{"#tup": […]}` → a tuple (the unit value `{"#tup": []}` → `{}`)
    * `{"tag": t, "value": v}` → `{:variant, t, v}`
    * any other object (a record) → a map with string keys
    * lists, strings, numbers and booleans stay as they are

  Module qualifiers are stripped from variable names, and each state's
  `#meta` is dropped. No atoms are created from trace data. Errors raise
  `AshQuint.ITF.Error` with the file and the JSON path.
  """

  alias AshQuint.ITF.Error
  alias AshQuint.Trace

  @doc """
  Reads and decodes the ITF file at `path`.
  """
  @spec read!(Path.t()) :: Trace.t()
  def read!(path) do
    case path |> File.read!() |> Jason.decode() do
      {:ok, json} ->
        decode!(json, path)

      {:error, error} ->
        raise Error, path: path, json_path: "$", reason: Exception.message(error)
    end
  end

  @doc """
  Decodes already-parsed ITF JSON. `path` is used in error messages and set
  on the trace.
  """
  @spec decode!(term(), String.t()) :: Trace.t()
  def decode!(%{"vars" => vars, "states" => states}, path)
      when is_list(vars) and is_list(states) do
    vars = vars |> Enum.uniq() |> strip_names("$.vars")

    states =
      states
      |> Enum.with_index()
      |> Enum.map(fn {state, index} -> decode_state(state, "$.states[#{index}]") end)

    %Trace{path: path, vars: vars, states: states}
  rescue
    error in Error -> reraise %{error | path: path}, __STACKTRACE__
  end

  def decode!(_json, path) do
    raise Error,
      path: path,
      json_path: "$",
      reason: "not an ITF trace (needs vars and states lists)"
  end

  @doc """
  Decodes one ITF value. `json_path` (like `$.states[2].m`) names the value
  in error messages.
  """
  @spec decode_value(term(), String.t()) :: term()
  def decode_value(%{"#bigint" => digits}, json_path) do
    case is_binary(digits) and Integer.parse(digits) do
      {integer, ""} ->
        integer

      _other ->
        raise Error,
          json_path: json_path,
          reason: "#bigint must be a string of decimal digits, got #{inspect(digits)}"
    end
  end

  def decode_value(%{"#map" => entries}, json_path) when is_list(entries) do
    entries
    |> Enum.with_index()
    |> Map.new(fn
      {[key, value], index} ->
        entry_path = "#{json_path}.#map[#{index}]"
        {decode_value(key, entry_path <> "[0]"), decode_value(value, entry_path <> "[1]")}

      {entry, index} ->
        raise Error,
          json_path: "#{json_path}.#map[#{index}]",
          reason: "a #map entry must be a [key, value] pair, got #{inspect(entry)}"
    end)
  end

  def decode_value(%{"#set" => elements}, json_path) when is_list(elements),
    do: elements |> decode_list(json_path <> ".#set") |> MapSet.new()

  def decode_value(%{"#tup" => elements}, json_path) when is_list(elements),
    do: elements |> decode_list(json_path <> ".#tup") |> List.to_tuple()

  def decode_value(%{"tag" => tag, "value" => value} = variant, json_path)
      when is_binary(tag) and map_size(variant) == 2,
      do: {:variant, tag, decode_value(value, json_path <> ".value")}

  def decode_value(map, json_path) when is_map(map) do
    case Map.keys(map) do
      ["#" <> _ = form] ->
        raise Error, json_path: json_path, reason: "unknown ITF form #{form}"

      _keys ->
        record =
          Map.new(map, fn {key, value} -> {key, decode_value(value, "#{json_path}.#{key}")} end)

        case bignumber(record) do
          {:ok, integer} -> integer
          :error -> record
        end
    end
  end

  def decode_value(list, json_path) when is_list(list), do: decode_list(list, json_path)

  def decode_value(scalar, _json_path), do: scalar

  @doc """
  Strips module qualifiers from a variable name: the part after the last
  `::` (`"tests::model::live"` → `"live"`).
  """
  @spec strip(String.t()) :: String.t()
  def strip(name), do: name |> String.split("::") |> List.last()

  # Quint (0.33.0 and 0.33.1) writes integers with |n| >= 10^15 as the
  # internals of a bignumber.js value: sign `s`, decimal exponent `e` of the
  # leading digit, and digits `c` in base-10^14 chunks. The first chunk holds
  # the leading (e mod 14) + 1 digits, each later chunk 14 digits, and
  # trailing zero chunks are dropped. Only a record consistent with that
  # layout is converted: exactly the fields s, e and c, and e >= 15, since
  # smaller integers are written as #bigint. Any other record stays a map.
  @chunk 100_000_000_000_000

  defp bignumber(%{"s" => s, "e" => e, "c" => [first | rest]} = record)
       when map_size(record) == 3 and s in [1, -1] and is_integer(e) and e >= 15 do
    if chunks?(first, rest, e) do
      coefficient = Enum.reduce(rest, first, &(&2 * @chunk + &1))
      zeros = e - rem(e, 14) - 14 * length(rest)
      {:ok, s * coefficient * Integer.pow(10, zeros)}
    else
      :error
    end
  end

  defp bignumber(_record), do: :error

  defp chunks?(first, rest, e) when is_integer(first) and first > 0,
    do:
      length(Integer.digits(first)) == rem(e, 14) + 1 and
        Enum.all?(rest, &(is_integer(&1) and &1 >= 0 and &1 < @chunk))

  defp chunks?(_first, _rest, _e), do: false

  defp decode_list(list, json_path) do
    list
    |> Enum.with_index()
    |> Enum.map(fn {value, index} -> decode_value(value, "#{json_path}[#{index}]") end)
  end

  defp decode_state(state, json_path) when is_map(state) do
    state = Map.delete(state, "#meta")
    names = state |> Map.keys() |> Enum.sort()
    stripped = strip_names(names, json_path)

    names
    |> Enum.zip(stripped)
    |> Map.new(fn {name, short} ->
      {short, decode_value(Map.fetch!(state, name), "#{json_path}.#{name}")}
    end)
  end

  defp decode_state(_state, json_path),
    do: raise(Error, json_path: json_path, reason: "a state must be an object")

  defp strip_names(names, json_path) do
    {stripped, _seen} =
      Enum.map_reduce(names, %{}, fn name, seen ->
        short = strip(name)

        case seen do
          %{^short => other} ->
            raise Error,
              json_path: json_path,
              reason: "#{other} and #{name} both strip to #{short}"

          %{} ->
            {short, Map.put(seen, short, name)}
        end
      end)

    stripped
  end
end

defmodule AshQuint.ITF.Error do
  @moduledoc """
  Raised when an ITF file can't be decoded: malformed JSON, an unknown ITF
  form (such as `#unserializable`), a `#bigint` that isn't a string of
  decimal digits, or two variable names that strip to the same name. The message names the file and the JSON path.
  """

  defexception [:path, :json_path, :reason]

  @type t :: %__MODULE__{
          path: String.t() | nil,
          json_path: String.t() | nil,
          reason: String.t()
        }

  @impl true
  @spec message(t()) :: String.t()
  def message(%__MODULE__{path: nil, json_path: json_path, reason: reason}),
    do: "#{json_path}: #{reason}"

  def message(%__MODULE__{path: path, json_path: json_path, reason: reason}),
    do: "#{path} at #{json_path}: #{reason}"
end
