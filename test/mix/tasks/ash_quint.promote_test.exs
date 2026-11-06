defmodule Mix.Tasks.AshQuint.PromoteTest do
  # The "with Quint" test runs real Quint through npx: excluded by default,
  # run with `mix test --only quint_cli`.
  use ExUnit.Case, async: false

  alias AshQuint.Gen
  alias AshQuint.Manifest
  alias Mix.Tasks.AshQuint.Promote

  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  @example "priv/examples/counter"
  @traces Path.join(@example, "traces")
  @manifest Path.join(@traces, "manifest.json")
  @target Path.join(@traces, "regression_4031_2.itf.json")

  setup %{tmp_dir: tmp_dir} do
    File.cp!("ash_quint.exs", Path.join(tmp_dir, "ash_quint.exs"))
    # The root config has both examples; gen --check needs them all.
    for example <- [@example, "priv/examples/race"] do
      File.mkdir_p!(Path.join(tmp_dir, example))
      File.cp_r!(example, Path.join(tmp_dir, example))
    end

    File.mkdir_p!(Path.join(tmp_dir, "candidates"))

    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    %{root: tmp_dir}
  end

  defp promote(root, argv), do: File.cd!(root, fn -> Promote.run(argv) end)

  defp infos do
    receive do
      {:mix_shell, :info, [line]} -> [line | infos()]
    after
      0 -> []
    end
  end

  # counter's random_0 as explore would leave it, written to
  # candidates/<name> in `root`; returns its path relative to `root`.
  defp candidate(root, name, overrides \\ %{}) do
    provenance =
      Map.merge(
        %{
          "model" => "counter",
          "model_hash" => Manifest.hash_file(Path.join(@example, "model.qnt")),
          "seed" => 4031,
          "index" => 2,
          "quint" => "0.33.1",
          "args" => ["run", Path.join(@example, "model.qnt"), "--seed=4031"],
          "steps" => 10,
          "cut_at" => nil
        },
        overrides
      )

    binary =
      @traces
      |> Path.join("random_0.itf.json")
      |> File.read!()
      |> Gen.put_provenance(provenance)

    path = Path.join("candidates", name)
    File.write!(Path.join(root, path), binary)
    path
  end

  defp snapshot(root) do
    dir = Path.join(root, @traces)
    Map.new(File.ls!(dir), &{&1, File.read!(Path.join(dir, &1))})
  end

  defp refuses(root, argv, message) do
    before = snapshot(root)
    assert_raise Mix.Error, message, fn -> promote(root, argv) end
    assert snapshot(root) == before
  end

  test "copies the candidate and adds its entry", %{root: root} do
    file = candidate(root, "a.itf.json")
    before = Manifest.read!(Path.join(root, @manifest))

    assert promote(root, [file]) == :ok

    assert File.read!(Path.join(root, @target)) == File.read!(Path.join(root, file))

    after_ = Manifest.read!(Path.join(root, @manifest))
    assert after_.interface == before.interface
    assert after_.models == before.models
    assert after_.seed == before.seed

    assert after_.traces -- before.traces == [
             Enum.find(after_.traces, &(&1.source == :regression))
           ]

    assert before.traces -- after_.traces == []

    assert %{file: "regression_4031_2.itf.json", name: "4031_2", seed: 4031, steps: 10} =
             Enum.find(after_.traces, &(&1.source == :regression))

    assert infos() == ["ash_quint.promote: counter: added regression_4031_2.itf.json (10 steps)"]
  end

  test "promotes several candidates", %{root: root} do
    a = candidate(root, "a.itf.json")
    b = candidate(root, "b.itf.json", %{"seed" => 9, "index" => 0})

    promote(root, [a, b])

    traces = Manifest.read!(Path.join(root, @manifest)).traces

    assert ["4031_2", "9_0"] ==
             for(%{source: :regression, name: name} <- traces, do: name)

    assert length(infos()) == 2
  end

  test "refuses a file without provenance", %{root: root} do
    path = "candidates/plain.itf.json"
    File.cp!(Path.join([root, @traces, "random_0.itf.json"]), Path.join(root, path))

    refuses(root, [path], "#{path}: not an ash_quint explore candidate")
  end

  test "refuses a candidate from another model version", %{root: root} do
    file = candidate(root, "a.itf.json", %{"model_hash" => "sha256:old"})

    refuses(
      root,
      [file],
      "#{file} was found against another version of #{@example}/model.qnt; " <>
        "run mix ash_quint.gen counter and explore again"
    )
  end

  test "refuses a candidate when the model changed since gen", %{root: root} do
    file = candidate(root, "a.itf.json")
    File.write!(Path.join([root, @example, "model.qnt"]), "// changed\n", [:append])

    refuses(
      root,
      [file],
      "#{file} was found against another version of #{@example}/model.qnt; " <>
        "run mix ash_quint.gen counter and explore again"
    )
  end

  test "refuses an existing target", %{root: root} do
    file = candidate(root, "a.itf.json")
    promote(root, [file])
    infos()

    refuses(root, [file], "#{file}: #{@target} already exists")
  end

  test "refuses two candidates with the same target", %{root: root} do
    a = candidate(root, "a.itf.json")
    b = candidate(root, "b.itf.json")

    refuses(root, [a, b], "#{b}: #{@target} already exists")
  end

  test "refuses an unknown model", %{root: root} do
    file = candidate(root, "a.itf.json", %{"model" => "nope"})

    refuses(root, [file], "model :nope is not configured in ash_quint.exs")
  end

  test "refuses a missing manifest", %{root: root} do
    file = candidate(root, "a.itf.json")
    File.rm!(Path.join(root, @manifest))

    refuses(
      root,
      [file],
      "#{file}: no manifest for :counter at #{@manifest}; " <>
        "run MIX_ENV=test mix ash_quint.gen counter"
    )
  end

  test "refuses a format 2 manifest", %{root: root} do
    file = candidate(root, "a.itf.json")
    path = Path.join(root, @manifest)

    json =
      path
      |> File.read!()
      |> Jason.decode!()
      |> Map.delete("interface")
      |> Map.put("ash_quint", 2)

    File.write!(path, Jason.encode!(json))

    refuses(
      root,
      [file],
      "#{file}: #{@manifest} is manifest format 2; " <>
        "run MIX_ENV=test mix ash_quint.gen counter first"
    )
  end

  test "refuses a candidate that doesn't follow the model convention", %{root: root} do
    file = candidate(root, "a.itf.json")
    path = Path.join(root, file)
    {:ok, provenance} = Gen.provenance(File.read!(path))

    binary =
      Jason.encode!(%{
        "#meta" => %{"format" => "ITF"},
        "vars" => ["n"],
        "states" => [%{"n" => 0}, %{"n" => 1}]
      })
      |> Gen.put_provenance(provenance)

    File.write!(path, binary)

    before = snapshot(root)

    error = assert_raise Mix.Error, fn -> promote(root, [file]) end
    assert error.message =~ ~r/^#{file}: regression_4031_2\.itf\.json, state 1: /
    assert snapshot(root) == before
  end

  test "one bad file writes nothing", %{root: root} do
    good = candidate(root, "a.itf.json")
    bad = candidate(root, "b.itf.json", %{"model_hash" => "sha256:old", "seed" => 1})

    refuses(
      root,
      [good, bad],
      "#{bad} was found against another version of #{@example}/model.qnt; " <>
        "run mix ash_quint.gen counter and explore again"
    )
  end

  test "an unknown flag is an error", %{root: root} do
    assert_raise OptionParser.ParseError, ~r/--force : Unknown option/, fn ->
      promote(root, ["--force"])
    end
  end

  test "no files is an error", %{root: root} do
    assert_raise Mix.Error, "usage: mix ash_quint.promote <candidate> ...", fn ->
      promote(root, [])
    end
  end

  @tag :quint_cli
  test "a promoted trace survives gen --check", %{root: root} do
    promote(root, [candidate(root, "a.itf.json")])
    infos()

    File.cd!(root, fn -> Mix.Tasks.AshQuint.Gen.run(["--check"]) end)
    assert infos() == ["ash_quint.gen: traces are current"]
  end
end
