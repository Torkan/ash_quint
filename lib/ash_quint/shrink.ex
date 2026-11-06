defmodule AshQuint.Shrink do
  @moduledoc """
  Shrinks an explore candidate: rebuilds its steps as a Quint `run`, and
  lets `quint test` judge shorter ones.

  A trace is determined by its action values (the model convention puts
  every pick of a step into its action value), so the run
  `init.then(inc("c1", 2)).then(reset("c1"))` replays it in Quint. A step
  becomes a call by convention: the action variant's name with its first
  letter lowercased is the operator; a record pick's fields, in the model
  interface's declaration order, are its arguments; a value or map pick is
  the one argument; a unit variant is called bare. With
  `shrink: [apply: "apply"]` every call is `apply(<the action value>)`
  instead, for a model action `apply(a: Action): bool` that matches on the
  variants.

  The wrapper imports the `random: [main: …]` module. An import doesn't
  re-export what that module imports, so when `main` is an instance module
  (`module counter_app { import counter(CAP = 5).* }`), set
  `shrink: [import: "counter(CAP = 5)"]` to import the instance itself.

  `shrink/3` runs the loop: round 0 checks that the candidate's calls give
  back its states, then each round removes chunks of the steps before the
  failing one and keeps the first reduction that Quint accepts as a run and
  whose replay still fails with the same action.
  """

  alias AshQuint.Config
  alias AshQuint.Config.Model
  alias AshQuint.Gen
  alias AshQuint.Interface
  alias AshQuint.ITF
  alias AshQuint.Shrink.Loop

  @typedoc """
  A replay's outcome: `:ok`, a failure at state `index` with the step's
  action and the failure message, or a raise (its banner).
  """
  @type replay_result ::
          :ok
          | {:failed, non_neg_integer(), String.t(), String.t()}
          | {:raised, String.t()}

  @typedoc """
  The options of `shrink/3`, all required: the project's `config`, the
  `model` and its `interface` (from the committed manifest), the Quint
  `runner` (see `AshQuint.Gen.generate/3`), the `replay` of a reduction
  (its ITF binary), `keep?`, a filter on reductions (the explore
  selection), and `dir`, under which each shrink gets a fresh work
  directory, removed afterwards.
  """
  @type shrink_opts :: [
          config: Config.t(),
          model: Model.t(),
          interface: Interface.t(),
          runner: Gen.runner(),
          replay: (binary() -> replay_result()),
          keep?: (binary() -> boolean()),
          dir: Path.t()
        ]

  @typedoc """
  A shrunk candidate: its step count, the rounds the loop ran (round 0
  isn't counted), its run expression, the message of its confirmation
  replay, and why the loop stopped early (`stopped`: a round's `quint
  test` wrote no runs), `nil` when it ended by itself or on its budget.
  """
  @type result :: %{
          steps: non_neg_integer(),
          rounds: non_neg_integer(),
          run: String.t(),
          message: String.t(),
          stopped: String.t() | nil
        }

  @doc """
  Renders one ITF JSON value (as `Jason.decode!/1` gives it) as a Quint
  expression: `#bigint` (and the bignumber.js object Quint writes for large
  integers) as an integer literal, strings as string literals, booleans,
  `#tup` as a tuple, variants as `Tag(v)` (`Tag` for unit), `#set` as
  `Set(…)`, `#map` as `Map(k -> v, …)`, lists as `[…]` and other objects as
  records `{ a: v }`, in the ITF's order.

  `:error` for what has no literal: a string with `"`, `\\` or a control
  character, `#unserializable`, a tuple of fewer than two elements, a tag
  or field that isn't a name, and any other shape.
  """
  @spec render(term()) :: {:ok, String.t()} | :error
  def render(value) do
    case do_render(value) do
      {:ok, text} -> {:ok, text}
      {:error, _culprit} -> :error
    end
  end

  # {:ok, text} or {:error, the innermost value that can't be rendered}.
  defp do_render(%{"#bigint" => digits} = value) when map_size(value) == 1 do
    if is_binary(digits) and digits =~ ~r/\A-?[0-9]+\z/, do: {:ok, digits}, else: {:error, value}
  end

  defp do_render(%{"#tup" => [_, _ | _] = elements} = value) when map_size(value) == 1,
    do: join(elements, "(", ")")

  defp do_render(%{"#set" => elements} = value) when map_size(value) == 1 and is_list(elements),
    do: join(elements, "Set(", ")")

  defp do_render(%{"#map" => entries} = value) when map_size(value) == 1 and is_list(entries) do
    entries
    |> map_all(fn
      [k, v] ->
        with {:ok, k} <- do_render(k), {:ok, v} <- do_render(v), do: {:ok, "#{k} -> #{v}"}

      entry ->
        {:error, entry}
    end)
    |> wrap("Map(", ")")
  end

  defp do_render(%{"tag" => tag, "value" => payload} = value) when map_size(value) == 2 do
    cond do
      not name?(tag) -> {:error, value}
      payload == %{"#tup" => []} -> {:ok, tag}
      true -> with {:ok, v} <- do_render(payload), do: {:ok, "#{tag}(#{v})"}
    end
  end

  defp do_render(%{"s" => _, "e" => _, "c" => _} = value) when map_size(value) == 3 do
    case ITF.decode_value(value, "$") do
      integer when is_integer(integer) -> {:ok, Integer.to_string(integer)}
      _record -> record(value)
    end
  end

  defp do_render(value) when is_map(value) and map_size(value) > 0, do: record(value)

  defp do_render(value) when is_list(value), do: join(value, "[", "]")
  defp do_render(value) when is_integer(value), do: {:ok, Integer.to_string(value)}
  defp do_render(value) when is_boolean(value), do: {:ok, Atom.to_string(value)}

  defp do_render(value) when is_binary(value) do
    if value =~ ~r/["\\\x00-\x1f\x7f]/, do: {:error, value}, else: {:ok, ~s("#{value}")}
  end

  defp do_render(value), do: {:error, value}

  defp record(value) do
    if Enum.all?(Map.keys(value), &name?/1) do
      value
      |> map_all(&field/1)
      |> wrap("{ ", " }")
    else
      {:error, value}
    end
  end

  defp field({key, value}), do: with({:ok, v} <- do_render(value), do: {:ok, "#{key}: #{v}"})

  defp join(elements, open, close), do: elements |> map_all(&do_render/1) |> wrap(open, close)

  defp wrap({:ok, texts}, open, close), do: {:ok, open <> Enum.join(texts, ", ") <> close}
  defp wrap({:error, _culprit} = error, _open, _close), do: error

  defp map_all(enumerable, fun) do
    enumerable
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, text} -> {:cont, {:ok, [text | acc]}}
        {:error, _culprit} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, texts} -> {:ok, Enum.reverse(texts)}
      error -> error
    end
  end

  defp name?(name), do: Config.quint_name?(name)

  @doc """
  The calls of the steps 1..N of `itf`, a raw ITF trace (as
  `Jason.decode!/1` gives it; records and `#map`s must stay apart, so not
  an `AshQuint.Trace`), from the action value at `model.action_path`: by
  convention from `interface`, or `apply(<value>)` with
  `model.shrink[:apply]` set. See the moduledoc.

  An error names the step: a value that can't be rendered (see
  `render/1`), an action that isn't in the interface, a record pick
  without one of the interface's fields, or no action variant at the path.
  """
  @spec calls(map(), Interface.t(), Model.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def calls(%{"states" => [_init | states]}, %Interface{} = interface, %Model{} = model) do
    apply_op = (model.shrink || [])[:apply]
    actions = Map.new(interface.actions, &{&1.name, &1})

    states
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {state, index}, {:ok, acc} ->
      case call(action_value(state, model.action_path), apply_op, actions) do
        {:ok, call} ->
          {:cont, {:ok, [call | acc]}}

        {:error, reason} ->
          {:halt, {:error, "step #{index}#{reason}"}}
      end
    end)
    |> case do
      {:ok, calls} -> {:ok, Enum.reverse(calls)}
      error -> error
    end
  end

  def calls(_itf, %Interface{}, %Model{}), do: {:ok, []}

  defp action_value(state, [root | rest]) do
    case Enum.find(state, fn {name, _} -> ITF.strip(name) == root end) do
      {_name, value} -> {Enum.join([root | rest], "."), dig(value, rest)}
      nil -> {Enum.join([root | rest], "."), nil}
    end
  end

  defp dig(value, []), do: value
  defp dig(%{} = value, [key | rest]), do: dig(Map.get(value, key), rest)
  defp dig(_value, _path), do: nil

  defp call({_path, %{"tag" => tag, "value" => payload} = value}, apply_op, actions)
       when is_binary(tag) and map_size(value) == 2 do
    case apply_op do
      nil -> convention(tag, payload, Map.get(actions, tag))
      op -> with {:ok, v} <- render_pick(tag, value), do: {:ok, "#{op}(#{v})"}
    end
  end

  defp call({path, value}, _apply_op, _actions),
    do: {:error, ": no action variant at #{path}, got #{inspect(value)}"}

  defp convention(tag, _payload, nil),
    do: {:error, ": action #{inspect(tag)} isn't in the model interface"}

  defp convention(tag, _payload, %{picks: :unit}), do: {:ok, operator(tag)}

  defp convention(tag, payload, %{picks: :record, fields: fields}) do
    fields
    |> map_all(fn %{name: field} ->
      case payload do
        %{^field => v} -> render_pick(tag, v)
        _other -> {:error, {:missing, field}}
      end
    end)
    |> case do
      {:ok, args} ->
        {:ok, "#{operator(tag)}(#{Enum.join(args, ", ")})"}

      {:error, {:missing, field}} ->
        {:error, " (#{tag}): no field #{inspect(field)} in #{inspect(payload)}"}

      error ->
        error
    end
  end

  defp convention(tag, payload, %{picks: picks}) when picks in [:value, :map] do
    with {:ok, v} <- render_pick(tag, payload), do: {:ok, "#{operator(tag)}(#{v})"}
  end

  defp render_pick(tag, value) do
    case do_render(value) do
      {:ok, text} -> {:ok, text}
      {:error, culprit} -> {:error, " (#{tag}): can't render #{inspect(culprit)}"}
    end
  end

  defp operator(<<first::utf8, rest::binary>>), do: String.downcase(<<first::utf8>>) <> rest

  # The run expression of `calls`: the model's init action
  # (`random: [init: …]`, default `init`) followed by `.then(call)` for
  # each.
  @doc false
  @spec run_expression(Model.t(), [String.t()]) :: String.t()
  def run_expression(%Model{} = model, calls) do
    init = (model.random || [])[:init] || "init"
    Enum.join([init | Enum.map(calls, &"then(#{&1})")], ".")
  end

  # The import path of the model file `model` (absolute) from the directory
  # `dir` (absolute): relative, without `.qnt`, starting with `./` or `../`.
  @doc false
  @spec import_path(Path.t(), Path.t()) :: String.t()
  def import_path(model, dir) do
    path = model |> Path.relative_to(dir, force: true) |> Path.rootname(".qnt")
    if String.starts_with?(path, "../"), do: path, else: "./" <> path
  end

  @doc """
  The wrapper module `ash_quint_shrink`: it imports the model's
  `random: [main: …]` module (or `shrink: [import: …]`, an instance like
  `counter(CAP = 5)`) from `import_path` (relative to the wrapper's
  directory, without `.qnt`) and declares one `run` per `{name, calls}`.
  """
  @spec wrapper(Model.t(), String.t(), [{String.t(), [String.t()]}]) :: String.t()
  def wrapper(%Model{} = model, import_path, runs) do
    main = (model.shrink || [])[:import] || Keyword.fetch!(model.random, :main)

    lines =
      Enum.map(runs, fn {name, calls} -> "  run #{name} = #{run_expression(model, calls)}\n" end)

    IO.iodata_to_binary([
      "module ash_quint_shrink {\n",
      ~s(  import #{main}.* from "#{import_path}"\n),
      lines,
      "}\n"
    ])
  end

  @doc """
  Shrinks `candidate`, a confirmed explore candidate (ITF binary) that
  fails at its last step with `action`. See `t:shrink_opts/0`.

    1. The steps become calls (`calls/3`). A single step isn't shrunk.
    2. Round 0 runs every call as one Quint `run`: it must pass, and its
       states must equal the candidate's, variable by variable.
    3. Each round writes one wrapper (`wrapper/3`)
       with a run per removal of a chunk of the steps before the failing
       one, and runs them all with one `quint test`. The runs Quint passed
       (`#meta.status` `"ok"`) are normalized, given the model's
       `#meta.source`, filtered with `keep?` and replayed in order; the
       first whose replay fails with `action`, at any step, is accepted,
       cut after that step. A round in which Quint writes no file at all
       ends the loop: with a reduction accepted, the result's `stopped`
       says so; without, the candidate isn't shrunk.
    4. The last accepted reduction is replayed once more, and must fail
       with `action` at its last step.

  Returns the shrunk trace, or `{:not_shrunk, reason}`.
  """
  @spec shrink(binary(), String.t(), shrink_opts()) ::
          {:ok, binary(), result()} | {:not_shrunk, String.t()}
  def shrink(candidate, action, opts) do
    model = Keyword.fetch!(opts, :model)
    json = Jason.decode!(candidate)
    n = length(json["states"]) - 1

    with :ok <- check_steps(n),
         {:ok, calls} <- calls(json, Keyword.fetch!(opts, :interface), model) do
      work =
        Path.join(
          Keyword.fetch!(opts, :dir),
          "#{model.name}_#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
        )

      File.mkdir_p!(work)

      try do
        session = %{
          config: Keyword.fetch!(opts, :config),
          model: model,
          runner: Keyword.fetch!(opts, :runner),
          replay: Keyword.fetch!(opts, :replay),
          keep?: Keyword.fetch!(opts, :keep?),
          action: action,
          calls: calls,
          work: work
        }

        with :ok <- round_zero(session, json) do
          session
          |> rounds(Loop.new(n, model.shrink[:rounds] || 20), nil)
          |> confirm(session)
        end
      after
        File.rm_rf!(work)
      end
    else
      {:error, reason} -> {:not_shrunk, reason}
      {:not_shrunk, _reason} = not_shrunk -> not_shrunk
    end
  end

  defp check_steps(n) when n <= 1, do: {:not_shrunk, "the failing step is the only step"}
  defp check_steps(_n), do: :ok

  defp round_zero(session, json) do
    {output, [file]} = quint_test(session, [Enum.to_list(0..(length(session.calls) - 1))])

    case file do
      nil ->
        {:not_shrunk,
         "quint test failed: #{first_line(output)}#{import_hint(session.model, output)}"}

      {_binary, %{"#meta" => %{"status" => "ok"}} = run} ->
        compare(ITF.decode!(json, "candidate"), ITF.decode!(run, "shrink_0"))

      _violation ->
        {:not_shrunk, "Quint doesn't accept the trace's calls as a run: #{qnt_line(output)}"}
    end
  rescue
    error in ITF.Error ->
      {:not_shrunk, "the model's run can't be read: #{Exception.message(error)}"}
  end

  # The first differing state and, in it, the first differing variable.
  defp compare(%{vars: vars, states: expected}, %{vars: run_vars, states: actual}) do
    vars = Enum.uniq(vars ++ run_vars)
    padded = Enum.max([length(expected), length(actual)])

    expected
    |> pad(padded)
    |> Enum.zip(pad(actual, padded))
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {{e, a}, index} ->
      case Enum.find(vars, &(e[&1] != a[&1] or is_nil(e) or is_nil(a))) do
        nil ->
          nil

        var ->
          {:not_shrunk,
           "the model's run differs from the trace at step #{index}, variable #{inspect(var)}"}
      end
    end)
  end

  defp pad(list, length), do: list ++ List.duplicate(nil, length - length(list))

  # Runs the loop until it's done, or a round writes no file: {loop, the
  # last accepted reduction as {binary, positions} or nil, why it stopped
  # early or nil}.
  defp rounds(_session, %Loop{done: true} = loop, last), do: {loop, last, nil}

  defp rounds(session, loop, last) do
    removals = Enum.map(Loop.removals(loop), &elem(&1, 1))
    {output, files} = quint_test(session, removals)

    if Enum.all?(files, &is_nil/1) do
      {loop, last, "quint test wrote no runs: #{first_line(output)}"}
    else
      case accept(session, Enum.zip(removals, files)) do
        nil -> rounds(session, Loop.advance(loop, nil), last)
        {_binary, kept} = accepted -> rounds(session, Loop.advance(loop, kept), accepted)
      end
    end
  end

  defp accept(session, runs) do
    Enum.find_value(runs, fn
      {kept, {binary, %{"#meta" => %{"status" => "ok"}}}} ->
        binary = binary |> Gen.normalize() |> Gen.put_source(session.model.model)

        with true <- session.keep?.(binary),
             {:failed, index, action, _message} when action == session.action and index >= 1 <-
               session.replay.(binary) do
          {Gen.cut(binary, index), Enum.take(kept, index)}
        else
          _other -> nil
        end

      _invalid ->
        nil
    end)
  end

  defp confirm({_loop, nil, nil}, _session), do: {:not_shrunk, "no step could be removed"}
  defp confirm({_loop, nil, stopped}, _session), do: {:not_shrunk, stopped}

  defp confirm({loop, {binary, kept}, stopped}, session) do
    last = length(kept)
    action = session.action

    case session.replay.(binary) do
      {:failed, ^last, ^action, message} ->
        run = run_expression(session.model, Enum.map(kept, &Enum.at(session.calls, &1)))

        {:ok, binary,
         %{steps: last, rounds: loop.rounds, run: run, message: message, stopped: stopped}}

      _other ->
        {:not_shrunk, "did not reproduce"}
    end
  end

  # One quint test over a run per list of positions (shrink_0, shrink_1,
  # …): Quint's output and each run's ITF as {binary, decoded}, nil when
  # not written or not JSON.
  defp quint_test(session, runs) do
    %{config: config, model: model, work: work} = session
    work |> Path.join("*.itf.json") |> Path.wildcard() |> Enum.each(&File.rm!/1)

    named =
      runs
      |> Enum.with_index()
      |> Enum.map(fn {positions, k} ->
        {"shrink_#{k}", Enum.map(positions, &Enum.at(session.calls, &1))}
      end)

    wrapper = Path.join(work, "ash_quint_shrink.qnt")
    import = import_path(Path.expand(model.model, config.root), work)
    File.write!(wrapper, wrapper(model, import, named))

    args =
      ["test", wrapper, "--main=ash_quint_shrink", "--match=^shrink_[0-9]+$", "--seed=1"] ++
        Gen.backend_args(model) ++ ["--out-itf=#{work}/{test}.itf.json"]

    output =
      case Gen.run_quint(config, args, session.runner) do
        {:ok, output, _status} -> output
        {:error, reason} -> reason
      end

    files =
      Enum.map(named, fn {name, _calls} ->
        with {:ok, binary} <- File.read(Path.join(work, "#{name}.itf.json")),
             {:ok, %{} = run} <- Jason.decode(binary) do
          {binary, run}
        else
          _unreadable -> nil
        end
      end)

    {output, files}
  end

  # A name the wrapper can't resolve, with no import: set: most likely an
  # instance module as main.
  defp import_hint(model, output) do
    if is_nil((model.shrink || [])[:import]) and String.contains?(output, "QNT404") do
      " (if random's main is an instance module, set shrink: [import: \"<module>(<constants>)\"])"
    else
      ""
    end
  end

  defp first_line(output) do
    output |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.find("", &(&1 != ""))
  end

  defp qnt_line(output) do
    lines = output |> String.split("\n") |> Enum.map(&String.trim/1)
    Enum.find(lines, &String.contains?(&1, "QNT")) || first_line(output)
  end
end
