defmodule AshQuint.Scaffold do
  @moduledoc """
  The source of an adapter skeleton and its test module, from a model's
  manifest (format 3, with the model's interface: see `AshQuint.Interface`).
  `mix ash_quint.gen.adapter` writes them.

  The adapter (`adapter_source/3`) has `init/2` returning `{:ok, %{}}`, one
  `step/2` clause per interface action except the model's `init_action`,
  `project/1` with every interface variable and a private `todo!/1` that
  raises `<Adapter>: <what> is not implemented yet`. It compiles without
  warnings, and every replay fails at its first step with that message.

    * Each clause binds its picks: a record's fields as variables (the field
      name underscored, `_` appended to Elixir's reserved words and `ctx`, a
      repeated name numbered), a value as `value`, a map as `picks`.
    * A concurrent action (the model has its `pending_result` and the
      action's record its `op_field`) takes its form from the manifest's
      outcomes: only `pending` gives `{:start, op, call, ctx}`, another
      outcome `{:complete, op, ctx}`, none (no trace takes it)
      `{:ok, result, ctx}` with a comment naming both.
    * `project/1` lists every variable with its type as a comment; the
      comment above it says to drop bookkeeping variables and allow-list
      them with `vars:`.

  The test module (`test_source/4`) uses `AshQuint.Case` with
  `sensitivity: true`, with comments on `traces:` (when the manifest has
  concurrent traces) and `explore:`.

  Both are formatted with `Code.format_string!/1`. Names from the manifest
  appear only as text in the source: no atoms are created from them.
  """

  alias AshQuint.Config.Model
  alias AshQuint.{Interface, Manifest}

  @reserved ~w(do end fn when and or not in true false nil catch rescue after else ctx)

  @doc """
  The source of the adapter module `adapter` for `model`, whose manifest
  (with an interface) is `manifest`.
  """
  @spec adapter_source(module(), Manifest.t(), Model.t()) :: String.t()
  def adapter_source(adapter, %Manifest{interface: %Interface{} = interface} = manifest, model) do
    outcomes = outcomes(manifest)

    clauses =
      case Enum.reject(interface.actions, &(&1.name == model.init_action)) do
        [] ->
          [
            "@impl true\ndef step(ctx, %Step{action_taken: action}), do: {:ok, todo!(action), ctx}"
          ]

        actions ->
          actions
          |> Enum.with_index()
          |> Enum.map(fn {action, index} ->
            clause(action, index == 0, form(action, interface, model, outcomes), model)
          end)
      end

    """
    defmodule #{inspect(adapter)} do
      @moduledoc \"""
      Replays the #{model.name} model's traces. Scaffolded by
      `mix ash_quint.gen.adapter`: replace each `todo!/1` with the system's
      call or state. See `AshQuint.Adapter`.
      \"""

      use AshQuint.Adapter

      alias AshQuint.Step

      @impl true
      def init(_trace, _opts), do: {:ok, %{}}

      #{Enum.join(clauses, "\n\n")}

      #{project(interface.vars)}

      defp todo!(what), do: raise("\#{inspect(__MODULE__)}: \#{what} is not implemented yet")
    end
    """
    |> format()
  end

  @doc """
  The source of the test module `test_module` that replays `model`'s
  traces (its manifest is `manifest`) with `adapter`.
  """
  @spec test_source(module(), module(), Manifest.t(), Model.t()) :: String.t()
  def test_source(test_module, adapter, %Manifest{} = manifest, model) do
    traces =
      if Enum.any?(manifest.traces, & &1.concurrent) do
        """
        # Concurrent traces run their ops in other processes, which a private ETS
        # table or a database sandbox may not allow: replay traces: :sequential
        # here and traces: :concurrent in an async: false module (see
        # AshQuint.Case).

        """
      else
        ""
      end

    explore =
      if model.random do
        """
        # explore: true adds a test that replays fresh traces, run with
        # mix ash_quint.explore; exclude it from mix test in test/test_helper.exs
        # with ExUnit.start(exclude: [:quint_explore]).
        """
      else
        """
        # explore: true needs random: for #{inspect(model.name)} in ash_quint.exs; it adds
        # a test that replays fresh traces, run with mix ash_quint.explore; exclude
        # it from mix test in test/test_helper.exs with
        # ExUnit.start(exclude: [:quint_explore]).
        """
      end

    """
    defmodule #{inspect(test_module)} do
      use ExUnit.Case, async: true

      #{traces}#{explore}use AshQuint.Case, model: #{inspect(model.name)}, adapter: #{inspect(adapter)}, sensitivity: true
    end
    """
    |> format()
  end

  defp format(source), do: IO.iodata_to_binary([Code.format_string!(source), "\n"])

  # Each action's outcome labels over the manifest's traces.
  defp outcomes(manifest) do
    for entry <- manifest.traces,
        {action, labels} <- entry.outcomes || %{},
        label <- Map.keys(labels),
        reduce: %{} do
      acc -> Map.update(acc, action, MapSet.new([label]), &MapSet.put(&1, label))
    end
  end

  defp form(%{picks: :record, fields: fields} = action, interface, model, outcomes) do
    concurrent =
      is_list(interface.results) and model.pending_result in interface.results and
        Enum.any?(fields, &(&1.name == model.op_field))

    labels = outcomes |> Map.get(action.name, MapSet.new()) |> MapSet.to_list()

    cond do
      not concurrent -> :ok
      labels == [] -> :never
      labels == ["pending"] -> :start
      true -> :complete
    end
  end

  defp form(_action, _interface, _model, _outcomes), do: :ok

  defp clause(action, first?, form, model) do
    {pattern, args, vars} = picks(action, form, model)

    {comment, body} =
      case form do
        :ok ->
          {[], "{:ok, todo!(#{args}), ctx}"}

        :never ->
          {[
             "No trace takes this action: return {:start, #{vars.op}, call, ctx} if it starts a call",
             "that stays in flight, {:complete, #{vars.op}, ctx} if it completes one."
           ], "{:ok, todo!(#{args}), ctx}"}

        :start ->
          {[
             "Use {:advance, #{vars.op}, ctx} if this action advances an op that started earlier."
           ], "{:start, #{vars.op}, fn -> todo!(#{args}) end, ctx}"}

        :complete ->
          {["The op's call was made by its start action; the replay checks its outcome here."],
           "{:complete, #{vars.op}, ctx}"}
      end

    comments =
      Enum.map_join([signature(action) | comment], "", &"# #{one_line(&1)}\n")

    impl = if first?, do: "@impl true\n", else: ""

    comments <>
      impl <>
      "def step(ctx, %Step{action_taken: #{inspect(action.name)}#{pattern}}) do\n" <>
      body <> "\nend"
  end

  # The pattern on nondet_picks, the todo!/1 argument (a string literal) and
  # the op variable.
  defp picks(%{picks: :unit} = action, _form, _model),
    do: {"", inspect(action.name), %{}}

  defp picks(%{picks: :value} = action, _form, _model),
    do: {~s(, nondet_picks: %{"value" => value}), call_text(action.name, ["value"]), %{}}

  defp picks(%{picks: :map} = action, _form, _model),
    do: {", nondet_picks: picks", call_text(action.name, ["picks"]), %{}}

  defp picks(%{picks: :record, fields: fields} = action, form, model) do
    {named, _taken} =
      Enum.map_reduce(fields, MapSet.new(), fn field, taken ->
        var = unique(variable(field.name), taken)
        {{field.name, var}, MapSet.put(taken, var)}
      end)

    op = Enum.find_value(named, fn {name, var} -> if name == model.op_field, do: var end)

    bound =
      Enum.map_join(named, ", ", fn {name, var} ->
        # A completion uses only its op.
        var = if form == :complete and name != model.op_field, do: "_" <> var, else: var
        "#{inspect(name)} => #{var}"
      end)

    args =
      "\"" <>
        lit(action.name) <>
        "(" <>
        Enum.map_join(named, ", ", fn {name, var} -> lit(name) <> ": \#{inspect(#{var})}" end) <>
        ")\""

    {", nondet_picks: %{#{bound}}", args, %{op: op}}
  end

  # "Name(#{inspect(var)})" as a string literal.
  defp call_text(name, [var]), do: "\"" <> lit(name) <> "(\#{inspect(#{var})})\""

  defp variable(field) do
    base = field |> Macro.underscore() |> String.trim_leading("_")

    base =
      if base =~ ~r/^[a-z][a-zA-Z0-9_]*$/,
        do: base,
        else: "v_" <> String.replace(base, ~r/[^a-zA-Z0-9_]/, "_")

    if base in @reserved, do: base <> "_", else: base
  end

  defp unique(var, taken, n \\ 1) do
    candidate = if n == 1, do: var, else: "#{var}_#{n}"
    if candidate in taken, do: unique(var, taken, n + 1), else: candidate
  end

  defp signature(%{picks: :unit, name: name}), do: name

  defp signature(%{picks: :record, name: name, fields: fields}),
    do: "#{name}({ #{Enum.map_join(fields, ", ", &"#{&1.name}: #{&1.type}")} })"

  defp signature(%{name: name, type: type}), do: "#{name}(#{type})"

  defp project([]), do: "@impl true\ndef project(_ctx), do: %{}"

  defp project(vars) do
    entries =
      Enum.map_join(vars, "\n", fn var ->
        "# #{one_line(var.type)}\n#{inspect(var.name)} => todo!(\"project #{lit(var.name)}\"),"
      end)

    """
    # Every variable of the model. Drop those that are the model's bookkeeping
    # rather than the system's state (ops in flight, say), and allow-list them
    # in the test module with sensitivity: [allow_untested: [vars: [...]]].
    @impl true
    def project(_ctx) do
      %{
        #{entries}
      }
    end
    """
  end

  # The text of a string literal's contents, escaped.
  defp lit(text), do: text |> inspect() |> String.slice(1..-2//1)

  defp one_line(text), do: String.replace(text, ~r/\s*\n\s*/, " ")
end
