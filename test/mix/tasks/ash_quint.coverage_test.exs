defmodule Mix.Tasks.AshQuint.CoverageTest do
  # Reads committed manifests only: no Node, no Quint.
  use ExUnit.Case, async: false

  alias Mix.Tasks.AshQuint.Coverage

  @moduletag :tmp_dir

  @example "priv/examples/counter"
  @manifest Path.join([@example, "traces", "manifest.json"])

  setup %{tmp_dir: tmp_dir} do
    File.cp!("ash_quint.exs", Path.join(tmp_dir, "ash_quint.exs"))
    # The root config has both examples.
    for example <- [@example, "priv/examples/race"] do
      File.mkdir_p!(Path.join(tmp_dir, example))
      File.cp_r!(example, Path.join(tmp_dir, example))
    end

    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    %{root: tmp_dir}
  end

  defp coverage(root, argv), do: File.cd!(root, fn -> Coverage.run(argv) end)

  defp infos do
    receive do
      {:mix_shell, :info, [line]} -> [line | infos()]
    after
      0 -> []
    end
  end

  test "prints the examples' tables", %{root: root} do
    assert coverage(root, []) == :ok

    # Starts are counted as pending and completions by their outcome; the
    # witness ends with both ops in flight, so there are two more starts.
    assert infos() == [
             "counter: 9 traces, 53 steps",
             "  Inc    23  accepted 20  rejected:over_limit 3",
             "  Peek   20  accepted 20",
             "  Reset  10  accepted 10",
             "race: 6 traces, 22 steps",
             "  IncDone   10  accepted 7  rejected:over_limit 3",
             "  IncStart  12  pending 12"
           ]
  end

  test "skips each model's init action", %{root: root} do
    config = Path.join(root, "ash_quint.exs")

    File.write!(
      config,
      String.replace(
        File.read!(config),
        ~s(out: "priv/examples/counter/traces",),
        ~s(out: "priv/examples/counter/traces", init_action: "Peek",)
      )
    )

    assert coverage(root, ["counter"]) == :ok

    assert infos() == [
             "counter: 9 traces, 53 steps",
             "  Inc    23  accepted 20  rejected:over_limit 3",
             "  Init    0",
             "  Peek   20  accepted 20",
             "  Reset  10  accepted 10"
           ]
  end

  test "takes model names", %{root: root} do
    assert coverage(root, ["counter"]) == :ok
    assert [_header, _inc, _peek, _reset] = infos()
  end

  test "an unknown model is an error", %{root: root} do
    assert_raise Mix.Error, "model :nope is not configured in ash_quint.exs", fn ->
      coverage(root, ["nope"])
    end
  end

  test "a manifest from before outcomes asks for a regeneration", %{root: root} do
    path = Path.join(root, @manifest)

    old =
      path
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("ash_quint", 1)
      |> Map.update!("traces", fn traces -> Enum.map(traces, &Map.delete(&1, "outcomes")) end)

    File.write!(path, Jason.encode!(old))

    assert_raise Mix.Error,
                 "counter: #{@manifest} was written before ash_quint recorded outcomes " <>
                   "(manifest format 1); run MIX_ENV=test mix ash_quint.gen counter " <>
                   "to regenerate it",
                 fn -> coverage(root, []) end
  end

  test "a missing manifest asks for a generation", %{root: root} do
    File.rm!(Path.join(root, @manifest))

    assert_raise Mix.Error,
                 "counter: no manifest at #{@manifest} (no such file or directory); " <>
                   "run MIX_ENV=test mix ash_quint.gen counter",
                 fn -> coverage(root, []) end
  end

  test "an invalid manifest is an error", %{root: root} do
    File.write!(Path.join(root, @manifest), "{")

    assert_raise Mix.Error,
                 ~r/^#{@manifest}: invalid JSON: .*; run MIX_ENV=test mix ash_quint.gen counter$/,
                 fn ->
                   coverage(root, [])
                 end
  end
end
