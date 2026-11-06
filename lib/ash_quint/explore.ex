defmodule AshQuint.Explore do
  @moduledoc """
  Explores a model: replays fresh `quint run` traces against the system and
  reports each failure as a candidate regression trace.

  A session is what the `"explore <model>"` test that `AshQuint.Case`
  defines with `explore:` runs (see `run!/2`), and that
  `mix ash_quint.explore` starts. It reads its settings from environment
  variables (`settings!/1`):

  | Variable | Default | Meaning |
  |---|---|---|
  | `ASH_QUINT_EXPLORE` | — | must be `1` (see `run!/2`) |
  | `ASH_QUINT_EXPLORE_RUNS` | 100 | fresh traces to generate |
  | `ASH_QUINT_EXPLORE_SEED` | random in 1..2^32-1 | base seed |
  | `ASH_QUINT_EXPLORE_BUDGET` | none | wall-clock seconds; no new batch starts after it |
  | `ASH_QUINT_EXPLORE_FAILURES` | 1 | stop after this many failures |

  The session runs batches k = 0, 1, …, each one `quint run` of the
  model's `random:` source (`AshQuint.Gen.random_args/3`) with seed
  `seed + k`, `--n-traces` and `--max-samples` both the batch size (the
  `batch` option, default 20, or the runs left), and `--max-steps` the
  `max_steps` option, else the model's. When the model's `witnesses:` have
  the same `main` as `random:`, each batch ends with
  `--witnesses <names…>`, and the report's `witnesses` sums, per name,
  the hits and traces Quint prints (`<name> was witnessed in <hits>
  trace(s) out of <traces> explored`); a batch whose output lacks a
  name's count makes them `:unknown`. Each fresh trace is normalized
  (`AshQuint.Gen.normalize/1`) and replayed with `AshQuint.Replay.run/3`
  in the calling process, named `"<seed>_<index>"` with source
  `:regression` and no `:context`, so its failure message is the start of
  the one its promoted test prints (which adds the `trace:` and `quint:`
  lines, see `AshQuint.Case`). The `traces:` selection applies: a trace it
  leaves out (by the manifest's `concurrent` rule) is only counted as
  skipped.

  A replay that fails at step N is cut to its states 0..N and replayed
  once more: if it fails at N again, the cut trace is the candidate,
  otherwise the full trace is. An exception from the adapter is a failure
  too, with the full trace. The candidate gets its provenance
  (`AshQuint.Gen.put_provenance/2`: model, model hash, seed, index, Quint
  version and arguments (without `--out-itf`, so they reproduce the batch
  with any out path), full step count, `cut_at`) and is written to
  `<build>/ash_quint/explore/<model>/regression_<seed>_<index>.itf.json`,
  from where `mix ash_quint.promote` commits it.

  With `shrink:` set for the model, a candidate confirmed this way is
  shrunk first (`AshQuint.Shrink.shrink/3`, with the interface of the
  committed manifest, read once per session, and work directories under
  `<build>/ash_quint/shrink/`); a reduction must stay in the `traces:`
  selection. A shrunk candidate is written instead of the confirmed one,
  with `shrunk` (`rounds`, `run`, `steps`) added to its provenance (whose
  `args` still regenerate the batch's original trace), and its
  confirmation replay's message becomes the failure's. A candidate that
  can't be shrunk is written as confirmed, with the reason in the report;
  shrinking that raises counts as not shrunk (`shrinking raised: …`), so
  it never fails the session.

  The session stops when `runs` traces are generated, `failures` failures
  are found, the budget is spent (checked before each batch but the
  first), Quint fails, or a fresh trace can't be normalized, decoded or
  selected; the last two are the report's `error`, after the failures
  found so far.
  """

  alias AshQuint.Config
  alias AshQuint.Config.Model
  alias AshQuint.Gen
  alias AshQuint.ITF
  alias AshQuint.Manifest
  alias AshQuint.Replay
  alias AshQuint.Shrink

  @type option ::
          {:model, atom()}
          | {:adapter, module()}
          | {:config, Path.t()}
          | {:adapter_opts, keyword()}
          | {:replay, [Replay.option()]}
          | {:traces, :all | :sequential | :concurrent}
          | {:max_steps, pos_integer() | nil}
          | {:batch, pos_integer()}

  @type settings :: %{
          runs: pos_integer(),
          seed: pos_integer(),
          budget: pos_integer() | nil,
          failures: pos_integer()
        }

  @type failure :: %{
          seed: pos_integer(),
          index: non_neg_integer(),
          message: String.t(),
          candidate: Path.t(),
          cut_at: non_neg_integer() | nil,
          reproduced: boolean() | nil,
          quint: String.t() | nil,
          shrunk: shrunk() | {:not_shrunk, String.t()} | nil
        }

  @typedoc """
  A shrunk candidate: the steps of the confirmed candidate (`from`), its
  own steps, the shrink rounds, its run expression and why the loop
  stopped early, or `nil` (see `t:AshQuint.Shrink.result/0`).
  """
  @type shrunk :: %{
          from: non_neg_integer(),
          steps: non_neg_integer(),
          rounds: non_neg_integer(),
          run: String.t(),
          stopped: String.t() | nil
        }

  @type report :: %{
          generated: non_neg_integer(),
          replayed: non_neg_integer(),
          skipped: non_neg_integer(),
          seeds: Range.t(),
          failures: [failure()],
          error: String.t() | nil,
          witnesses: [witness_rate()] | :unknown
        }

  @type witness_rate :: %{
          name: String.t(),
          hits: non_neg_integer(),
          traces: non_neg_integer()
        }

  @max_seed 4_294_967_295

  @doc """
  The session settings from environment variables (`System.get_env/0`):
  see the table in the module doc. A value that isn't a positive integer
  raises `ArgumentError` naming the variable.
  """
  @spec settings!(%{String.t() => String.t()}) :: settings()
  def settings!(env) do
    %{
      runs: positive!(env, "ASH_QUINT_EXPLORE_RUNS") || 100,
      seed: positive!(env, "ASH_QUINT_EXPLORE_SEED") || :rand.uniform(@max_seed),
      budget: positive!(env, "ASH_QUINT_EXPLORE_BUDGET"),
      failures: positive!(env, "ASH_QUINT_EXPLORE_FAILURES") || 1
    }
  end

  defp positive!(env, name) do
    case Map.fetch(env, name) do
      :error ->
        nil

      {:ok, value} ->
        case Integer.parse(value) do
          {integer, ""} when integer > 0 ->
            integer

          _other ->
            raise ArgumentError, "#{name} must be a positive integer, got #{inspect(value)}"
        end
    end
  end

  @doc """
  Runs a session with `settings` and returns its report.

  Options (`t:option/0`): `:model` and `:adapter` (required), `:config`
  (default `"ash_quint.exs"`, read with `AshQuint.Config.load!/1`),
  `:adapter_opts` and `:replay` (as in `AshQuint.Case`), `:traces`
  (default `:all`), `:max_steps` (default the model's `random:` one) and
  `:batch` (default 20).

  `run_opts`, for tests:

    * `:runner` — runs Quint, as in `AshQuint.Gen.generate/3`.
    * `:build_dir` — where candidates go under `ash_quint/explore/<model>`
      (default `Mix.Project.build_path/0`).
    * `:tmp_dir` — where each batch's temporary directory goes (default
      `System.tmp_dir!/0`).
    * `:now` — the clock for the budget, in ms (default
      `System.monotonic_time(:millisecond)`).
  """
  @spec run(settings(), [option()], keyword()) :: report()
  def run(settings, opts, run_opts \\ []) do
    config = Config.load!(Keyword.get(opts, :config, "ash_quint.exs"))
    model = Config.model!(config, Keyword.fetch!(opts, :model))

    unless model.random do
      raise ArgumentError, "explore needs random: for #{inspect(model.name)} in ash_quint.exs"
    end

    now = Keyword.get(run_opts, :now, fn -> System.monotonic_time(:millisecond) end)

    session = %{
      settings: settings,
      config: config,
      model: model,
      adapter: Keyword.fetch!(opts, :adapter),
      traces: Keyword.get(opts, :traces, :all),
      batch: Keyword.get(opts, :batch, 20),
      max_steps: Keyword.get(opts, :max_steps) || model.random[:max_steps],
      witnesses: witness_names(model),
      replay_opts: replay_opts(model, opts),
      interface: interface(config, model),
      model_hash: Manifest.hash_file(Path.join(config.root, model.model)),
      runner: Keyword.get(run_opts, :runner, &default_runner/3),
      out: Path.join([build_dir(run_opts), "ash_quint", "explore", to_string(model.name)]),
      shrink_dir: Path.join([build_dir(run_opts), "ash_quint", "shrink"]),
      tmp_dir: Keyword.get_lazy(run_opts, :tmp_dir, &System.tmp_dir!/0),
      now: now,
      start: now.()
    }

    report = %{
      generated: 0,
      replayed: 0,
      skipped: 0,
      seeds: settings.seed..settings.seed,
      failures: [],
      error: nil,
      witnesses: Enum.map(witness_names(model), &%{name: &1, hits: 0, traces: 0})
    }

    session
    |> batches(report, 0)
    |> Map.update!(:failures, &Enum.reverse/1)
  end

  # The witnesses each batch asks Quint to count: only when they are
  # predicates of the module random: runs.
  defp witness_names(%Model{witnesses: witnesses, random: random}) do
    if witnesses && witnesses[:main] == random[:main],
      do: witnesses[:names] || [],
      else: []
  end

  # The model interface shrinking needs, read once per session; nil without
  # shrink:.
  defp interface(_config, %Model{shrink: nil}), do: nil

  defp interface(config, model) do
    case Manifest.load(config, model, need: :interface) do
      {:ok, manifest} -> {:ok, manifest.interface}
      {:error, message} -> {:error, message}
    end
  end

  defp build_dir(run_opts), do: Keyword.get_lazy(run_opts, :build_dir, &Mix.Project.build_path/0)

  defp default_runner(cmd, args, opts) do
    System.cmd(cmd, args, opts ++ [stderr_to_stdout: true])
  end

  defp replay_opts(model, opts) do
    Model.replay_opts(model) ++
      [adapter_opts: Keyword.get(opts, :adapter_opts, [])] ++ Keyword.get(opts, :replay, [])
  end

  defp batches(session, report, k) do
    settings = session.settings
    requested = min(k * session.batch, settings.runs)

    cond do
      requested >= settings.runs or length(report.failures) >= settings.failures ->
        report

      k > 0 and settings.budget != nil and
          session.now.() - session.start >= settings.budget * 1000 ->
        report

      true ->
        seed = settings.seed + k
        size = min(session.batch, settings.runs - requested)
        report = %{report | seeds: settings.seed..seed}

        case batch(session, report, seed, size) do
          {:cont, report} -> batches(session, report, k + 1)
          {:halt, report} -> report
        end
    end
  end

  defp batch(session, report, seed, size) do
    suffix = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    tmp = Path.join(session.tmp_dir, "ash_quint_explore_" <> suffix)
    File.mkdir_p!(tmp)

    try do
      args =
        Gen.random_args(session.model, seed,
          n_traces: size,
          max_samples: size,
          max_steps: session.max_steps,
          out: Path.join(tmp, "explore_{seq}.itf.json")
        ) ++ witness_args(session.witnesses)

      case Gen.run_quint(session.config, args, session.runner) do
        {:ok, output, 0} ->
          report = %{
            report
            | generated: report.generated + size,
              witnesses: add_rates(report.witnesses, output)
          }

          replay_all(session, report, files(tmp), seed, args)

        {:ok, output, _status} ->
          message = "quint run for #{inspect(session.model.name)} explore failed:\n#{output}"
          {:halt, %{report | error: message}}

        {:error, message} ->
          {:halt, %{report | error: message}}
      end
    after
      File.rm_rf!(tmp)
    end
  end

  defp witness_args([]), do: []
  defp witness_args(names), do: ["--witnesses" | names]

  # The rates plus a batch's counts from Quint's output; a batch without a
  # name's count makes them unknown for the rest of the session.
  defp add_rates(:unknown, _output), do: :unknown

  defp add_rates(rates, output) do
    counts =
      ~r/^(\S+) was witnessed in (\d+) trace\(s\) out of (\d+) explored/m
      |> Regex.scan(output, capture: :all_but_first)
      |> Map.new(fn [name, hits, traces] ->
        {name, {String.to_integer(hits), String.to_integer(traces)}}
      end)

    Enum.reduce_while(rates, [], fn rate, acc ->
      case Map.fetch(counts, rate.name) do
        {:ok, {hits, traces}} ->
          {:cont, [%{rate | hits: rate.hits + hits, traces: rate.traces + traces} | acc]}

        :error ->
          {:halt, :unknown}
      end
    end)
    |> case do
      :unknown -> :unknown
      acc -> Enum.reverse(acc)
    end
  end

  # The batch's files in index order.
  defp files(tmp) do
    tmp
    |> File.ls!()
    |> Enum.flat_map(fn file ->
      case Regex.run(~r/\Aexplore_(\d+)\.itf\.json\z/, file) do
        [_, index] -> [{String.to_integer(index), Path.join(tmp, file)}]
        nil -> []
      end
    end)
    |> Enum.sort()
  end

  defp replay_all(session, report, files, seed, args) do
    Enum.reduce_while(files, {:cont, report}, fn {index, path}, {:cont, report} ->
      case fresh(session, path, seed, index) do
        {:ok, fresh} -> next(session, explore(session, report, fresh, {seed, index, args}))
        {:error, message} -> {:halt, {:halt, %{report | error: message}}}
      end
    end)
  end

  defp next(session, report) do
    if length(report.failures) >= session.settings.failures,
      do: {:halt, {:halt, report}},
      else: {:cont, {:cont, report}}
  end

  # A fresh trace normalized, decoded and checked against the selection;
  # one that can't be is the session's error.
  defp fresh(session, path, seed, index) do
    binary = Gen.normalize(File.read!(path))
    trace = decode(binary, "#{seed}_#{index}", seed)
    {:ok, %{binary: binary, trace: trace, selected: selected?(session, trace, index)}}
  rescue
    error in [Jason.DecodeError, ITF.Error, ArgumentError] ->
      {:error,
       "fresh trace #{seed}_#{index} of #{inspect(session.model.name)} could not be read: " <>
         Exception.message(error)}
  end

  defp explore(_session, report, %{selected: false}, _origin),
    do: %{report | skipped: report.skipped + 1}

  defp explore(session, report, %{binary: binary, trace: trace}, {seed, index, _args} = origin) do
    report = %{report | replayed: report.replayed + 1}

    case replay(session, trace) do
      :ok ->
        report

      {:failed, failure_index, action, message} ->
        {candidate, cut_at, reproduced} =
          confirm(session, binary, trace.name, seed, failure_index)

        shrunk = if reproduced, do: shrink(session, candidate, action, trace, index)

        failure =
          failure(session, origin, binary, {candidate, message, cut_at, reproduced}, shrunk)

        %{report | failures: [failure | report.failures]}

      {:raised, banner} ->
        message = "#{session.model.name} regression #{seed}_#{index}: #{banner}"
        failure = failure(session, origin, binary, {binary, message, nil, nil}, nil)
        %{report | failures: [failure | report.failures]}
    end
  end

  # A confirmed candidate shrunk (`{:ok, binary, shrunk}`), or why not; nil
  # without shrink:. Shrinking never fails the session: an exception leaves
  # the candidate unshrunk.
  defp shrink(%{interface: nil}, _candidate, _action, _trace, _index), do: nil

  defp shrink(%{interface: {:error, message}}, _candidate, _action, _trace, _index),
    do: {:not_shrunk, message}

  defp shrink(%{interface: {:ok, interface}} = session, candidate, action, trace, index) do
    %{name: name, seed: seed} = trace

    Shrink.shrink(candidate, action,
      config: session.config,
      model: session.model,
      interface: interface,
      runner: session.runner,
      replay: &replay(session, decode(&1, name, seed)),
      keep?: &keep?(session, &1, name, seed, index),
      dir: session.shrink_dir
    )
  rescue
    error -> {:not_shrunk, "shrinking raised: " <> Exception.message(error)}
  end

  # A reduction must decode, since the replay decodes it outside its
  # rescue, and stay in the selection that found the candidate.
  defp keep?(session, binary, name, seed, index) do
    selected?(session, decode(binary, name, seed), index)
  rescue
    _error in [Jason.DecodeError, ITF.Error, ArgumentError] -> false
  end

  defp decode(binary, name, seed) do
    trace = ITF.decode!(Jason.decode!(binary), "explore " <> name)
    %{trace | name: name, source: :regression, seed: seed}
  end

  defp selected?(%{traces: :all}, _trace, _index), do: true

  defp selected?(session, trace, index) do
    file = Gen.regression_file(trace.seed, index)
    entry = Gen.entry(file, :regression, trace.name, trace, session.model)
    entry.concurrent == (session.traces == :concurrent)
  end

  defp replay(session, trace) do
    case Replay.run(session.adapter, trace, session.replay_opts) do
      {:ok, _report} ->
        :ok

      {:error, %{index: index, action: action, message: message}} ->
        {:failed, index, action, message}
    end
  catch
    kind, reason -> {:raised, Exception.format_banner(kind, reason, __STACKTRACE__)}
  end

  # The candidate: the trace cut after its failing step, when a second
  # replay of the cut trace fails at the same step; else the full trace.
  defp confirm(session, binary, name, seed, failure_index) do
    states = length(Jason.decode!(binary)["states"])

    if failure_index == states - 1 do
      {binary, nil, reproduced?(session, binary, name, seed, failure_index)}
    else
      cut = Gen.cut(binary, failure_index)

      if reproduced?(session, cut, name, seed, failure_index),
        do: {cut, failure_index, true},
        else: {binary, nil, false}
    end
  end

  defp reproduced?(session, binary, name, seed, failure_index) do
    match?(
      {:failed, ^failure_index, _action, _message},
      replay(session, decode(binary, name, seed))
    )
  end

  defp failure(session, {seed, index, args}, full, confirmed, shrunk) do
    {candidate, message, cut_at, reproduced} = confirmed

    provenance = %{
      "model" => to_string(session.model.name),
      "model_hash" => session.model_hash,
      "seed" => seed,
      "index" => index,
      "quint" => session.config.quint,
      # Without the batch's temp --out-itf path, which means nothing later.
      "args" => Enum.reject(args, &String.starts_with?(&1, "--out-itf=")),
      "steps" => length(Jason.decode!(full)["states"]) - 1,
      "cut_at" => cut_at
    }

    {candidate, provenance, message, shrunk} =
      case shrunk do
        {:ok, binary, %{steps: steps, rounds: rounds, run: run, message: message} = result} ->
          from = length(Jason.decode!(candidate)["states"]) - 1
          recorded = %{"rounds" => rounds, "run" => run, "steps" => steps}

          {binary, Map.put(provenance, "shrunk", recorded), message,
           %{from: from, steps: steps, rounds: rounds, run: run, stopped: result.stopped}}

        other ->
          {candidate, provenance, message, other}
      end

    path = Path.join(session.out, Gen.regression_file(seed, index))
    File.mkdir_p!(session.out)
    File.write!(path, Gen.put_provenance(candidate, provenance))

    %{
      seed: seed,
      index: index,
      message: message,
      candidate: path,
      cut_at: cut_at,
      reproduced: reproduced,
      quint: Gen.quint_line(session.config, provenance),
      shrunk: shrunk
    }
  end

  @doc """
  What the `"explore <model>"` test runs (see `AshQuint.Case`): unless
  `ASH_QUINT_EXPLORE` is `1`, flunks at once, since the test was meant to
  be excluded from the suite; otherwise runs a session (`run/3`, with
  `settings!/1` of the environment and `opts`), prints its summary line
  (and its witnesses line, see `format/2`), and flunks with `format/2`
  when it found failures or Quint failed. `run_opts` are `run/3`'s, for
  tests.
  """
  @spec run!([option()], keyword()) :: :ok
  def run!(opts, run_opts \\ []) do
    model = Keyword.fetch!(opts, :model)

    unless System.get_env("ASH_QUINT_EXPLORE") == "1" do
      ExUnit.Assertions.flunk(
        "explore test for #{inspect(model)} ran without mix ash_quint.explore; " <>
          "add :quint_explore to ExUnit.start(exclude: …) in test/test_helper.exs"
      )
    end

    settings =
      try do
        settings!(System.get_env())
      rescue
        error in ArgumentError -> ExUnit.Assertions.flunk(Exception.message(error))
      end

    report = run(settings, opts, run_opts)
    IO.puts(summary(model, report))

    if report.failures != [] or report.error != nil do
      ExUnit.Assertions.flunk(format(model, report))
    end

    :ok
  end

  @doc """
  The report as text. A session without failures or error is one line:
  `explore counter: 100 traces (seeds 4031..4035), 0 failures, 0 skipped`,
  followed, when the report has witnesses and a batch ran, by
  `witnesses: witOverLimit 35/100 (35.0%), witResetAfterInc 100/100 (100.0%)`
  (`0/100 (never)` for a witness never hit,
  `witnesses: counts not found in Quint's output` when they are
  `:unknown`).
  Otherwise a header line counts the failures, followed, each after a
  blank line, by each failure's message, its candidate (relative to the
  current directory), with shrinking `shrunk from <n> to <m> steps (<k>
  rounds)` (and `stopped:   <reason>` when the loop stopped early) or
  `not shrunk: <reason>`, the `quint run` command that
  regenerates its trace as the batch generated it
  (`AshQuint.Gen.quint_line/2`), a shrunk candidate's `run:` expression
  and the `mix ash_quint.promote` command
  for it, and then the error.
  """
  @spec format(atom(), report()) :: String.t()
  def format(model, %{failures: [], error: nil} = report), do: summary(model, report)

  def format(model, report) do
    header =
      case report.failures do
        [] ->
          summary(model, report)

        failures ->
          "explore #{model}: #{count(length(failures), "failure")} in " <>
            "#{count(report.generated, "trace")} (seeds #{seeds(report)})"
      end

    blocks = Enum.map(report.failures, &failure_block/1)
    Enum.join([header | blocks] ++ List.wrap(report.error), "\n\n")
  end

  defp summary(model, report) do
    line =
      "explore #{model}: #{count(report.generated, "trace")} (seeds #{seeds(report)}), " <>
        "#{count(length(report.failures), "failure")}, #{report.skipped} skipped"

    case witnesses_line(report) do
      nil -> line
      witnesses -> line <> "\n" <> witnesses
    end
  end

  # No line without witnesses, nor before a batch has run.
  defp witnesses_line(%{witnesses: []}), do: nil
  defp witnesses_line(%{generated: 0}), do: nil
  defp witnesses_line(%{witnesses: :unknown}), do: "witnesses: counts not found in Quint's output"

  defp witnesses_line(%{witnesses: rates}),
    do: "witnesses: " <> Enum.map_join(rates, ", ", &rate/1)

  defp rate(%{name: name, hits: 0, traces: traces}), do: "#{name} 0/#{traces} (never)"

  defp rate(%{name: name, hits: hits, traces: traces}) do
    pct = :erlang.float_to_binary(hits * 100 / traces, decimals: 1)
    "#{name} #{hits}/#{traces} (#{pct}%)"
  end

  defp failure_block(failure) do
    path = Path.relative_to_cwd(failure.candidate)

    how =
      case failure do
        %{reproduced: nil} -> "adapter raised; full trace"
        %{reproduced: false} -> "did not reproduce on a second replay; full trace"
        %{cut_at: nil} -> "not cut"
        %{cut_at: cut_at} -> "cut to #{cut_at} steps"
      end

    quint = if failure.quint, do: ["quint:     " <> failure.quint], else: []

    {shrunk, run} = shrunk_lines(Map.get(failure, :shrunk))

    Enum.join(
      ["#{failure.message}", "candidate: #{path} (#{how})"] ++
        shrunk ++ quint ++ run ++ ["promote:   MIX_ENV=test mix ash_quint.promote #{path}"],
      "\n"
    )
  end

  # The shrink lines after the candidate line, and the run line after quint:.
  defp shrunk_lines(%{from: from, steps: steps, rounds: rounds, run: run} = shrunk) do
    stopped =
      case Map.get(shrunk, :stopped) do
        nil -> []
        reason -> ["stopped:   " <> reason]
      end

    {["shrunk from #{from} to #{steps} steps (#{rounds} rounds)" | stopped],
     ["run:       " <> run]}
  end

  defp shrunk_lines({:not_shrunk, reason}), do: {["not shrunk: " <> reason], []}
  defp shrunk_lines(nil), do: {[], []}

  defp seeds(%{seeds: first..last//_}), do: "#{first}..#{last}"

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"
end
