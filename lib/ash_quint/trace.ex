defmodule AshQuint.Trace do
  @moduledoc """
  A decoded Quint ITF trace.

  `vars` lists the trace's variable names with module qualifiers stripped
  (`"tests::model::count"` becomes `"count"`), and `states` holds one map per
  state, keyed by those names, with values decoded by `AshQuint.ITF`.

  `name`, `source` and `seed` come from the manifest; they are `nil` for a
  trace read with `AshQuint.ITF.read!/1`.
  """

  @enforce_keys [:path, :vars, :states]
  defstruct name: nil, source: nil, seed: nil, path: nil, vars: [], states: []

  @type source :: :random | :witness | :scenario

  @type t :: %__MODULE__{
          name: String.t() | nil,
          source: source() | nil,
          path: String.t(),
          seed: integer() | nil,
          vars: [String.t()],
          states: [map()]
        }

  @doc """
  Reads the trace at `path` with `AshQuint.ITF.read!/1` and sets the
  manifest fields `:name`, `:source` and `:seed` from `opts`.
  """
  @spec load!(Path.t(), name: String.t(), source: source(), seed: integer()) :: t()
  def load!(path, opts) do
    %{
      AshQuint.ITF.read!(path)
      | name: Keyword.fetch!(opts, :name),
        source: Keyword.fetch!(opts, :source),
        seed: Keyword.fetch!(opts, :seed)
    }
  end

  @doc """
  The trace's name in test names and failure messages: `"<source> <name>"`,
  such as `"random 7"` or `"scenario incTest"`. Takes a trace or a manifest
  entry.
  """
  @spec label(%{
          :source => source() | nil,
          :name => String.t() | nil,
          optional(atom()) => term()
        }) :: String.t()
  def label(%{source: source, name: name}), do: "#{source} #{name}"
end
