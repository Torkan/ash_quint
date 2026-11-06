defmodule Mix.Tasks.AshQuint.GenTest do
  # The "with Quint" tests run real Quint through npx: excluded by default,
  # run with `mix test --only quint_cli`.
  use ExUnit.Case, async: false

  alias Mix.Tasks.AshQuint.Gen

  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  @example "priv/examples/counter"
  @traces Path.join(@example, "traces")

  setup %{tmp_dir: tmp_dir} do
    File.cp!("ash_quint.exs", Path.join(tmp_dir, "ash_quint.exs"))
    # The root config has both examples; --check needs them all.
    for example <- [@example, "priv/examples/race"] do
      File.mkdir_p!(Path.join(tmp_dir, example))
      File.cp_r!(example, Path.join(tmp_dir, example))
    end

    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    %{root: tmp_dir}
  end

  defp gen(root, argv), do: File.cd!(root, fn -> Gen.run(argv) end)

  defp infos do
    receive do
      {:mix_shell, :info, [line]} -> [line | infos()]
    after
      0 -> []
    end
  end

  defp trace_files(dir), do: dir |> File.ls!() |> Enum.sort()

  test "an unknown model is an error", %{root: root} do
    assert_raise Mix.Error, "model :nope is not configured in ash_quint.exs", fn ->
      gen(root, ["counter", "nope"])
    end
  end

  test "an unknown flag is an error", %{root: root} do
    assert_raise OptionParser.ParseError, ~r/--force : Unknown option/, fn ->
      gen(root, ["--force"])
    end
  end

  describe "with Quint" do
    @describetag :quint_cli

    test "generates the counter traces byte for byte", %{root: root} do
      File.rm_rf!(Path.join(root, @traces))
      gen(root, ["counter"])

      assert trace_files(Path.join(root, @traces)) == trace_files(@traces)

      for file <- trace_files(@traces) do
        assert File.read!(Path.join([root, @traces, file])) ==
                 File.read!(Path.join(@traces, file)),
               "#{file} differs"
      end

      count = length(trace_files(@traces)) - 1

      assert infos() == [
               "ash_quint.gen: counter: wrote #{count} traces to #{@traces}",
               "counter: 9 traces, 53 steps",
               "  Inc    23  accepted 20  rejected:over_limit 3",
               "  Peek   20  accepted 20",
               "  Reset  10  accepted 10"
             ]
    end

    test "--check passes when current and exits 1 after a model change", %{root: root} do
      gen(root, ["--check"])
      assert infos() == ["ash_quint.gen: traces are current"]

      File.write!(Path.join([root, @example, "model.qnt"]), "// changed\n", [:append])

      assert catch_exit(gen(root, ["--check"])) == {:shutdown, 1}
      assert infos() == ["ash_quint.gen: counter (#{@traces}):", "  change manifest.json"]
    end

    # The interfaces asserted in AshQuint.InterfaceTest, from the IR fixtures.
    test "records the counter and race interfaces", %{root: root} do
      for model <- ["counter", "race"],
          do: File.rm_rf!(Path.join([root, "priv/examples", model, "traces"]))

      gen(root, ["counter", "race"])

      for model <- ["counter", "race"] do
        path = Path.join([root, "priv/examples", model, "traces/manifest.json"])

        {:ok, interface} =
          "test/fixtures/quint_ir/#{model}.json"
          |> File.read!()
          |> Jason.decode!()
          |> AshQuint.Interface.from_ir(action_path: ["lastAction"], result_path: ["lastResult"])

        assert %AshQuint.Manifest{version: 3, interface: ^interface} =
                 AshQuint.Manifest.read!(path)
      end
    end

    test "--dry-run writes nothing", %{root: root} do
      file = Path.join([root, @traces, "witness_witOverLimit.itf.json"])
      File.rm!(file)
      stale = Path.join([root, @traces, "random_9.itf.json"])
      File.write!(stale, "{}")

      gen(root, ["--dry-run", "counter"])

      assert infos() == [
               "ash_quint.gen: counter (#{@traces}):",
               "  add witness_witOverLimit.itf.json",
               "  remove random_9.itf.json"
             ]

      refute File.exists?(file)
      assert File.read!(stale) == "{}"
    end
  end
end
