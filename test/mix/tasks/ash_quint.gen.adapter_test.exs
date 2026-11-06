defmodule Mix.Tasks.AshQuint.Gen.AdapterTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.AshQuint.Gen.Adapter

  @moduletag :tmp_dir

  @manifest "priv/examples/counter/traces/manifest.json"
  @adapter_file "test/support/counter_trace.ex"
  @test_file "test/counter_trace_test.exs"

  setup %{tmp_dir: tmp_dir} do
    File.cp!("ash_quint.exs", Path.join(tmp_dir, "ash_quint.exs"))

    for example <- ["priv/examples/counter", "priv/examples/race"] do
      File.mkdir_p!(Path.join(tmp_dir, example))
      File.cp_r!(example, Path.join(tmp_dir, example))
    end

    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    %{root: tmp_dir}
  end

  defp gen(root, argv), do: File.cd!(root, fn -> Adapter.run(argv) end)

  defp read(root, path), do: File.read!(Path.join(root, path))

  test "writes the adapter and the test module", %{root: root} do
    gen(root, ["counter"])

    assert read(root, @adapter_file) =~ "defmodule AshQuint.CounterTrace do\n"
    assert read(root, @adapter_file) =~ ~s(action_taken: "Inc")

    assert read(root, @test_file) =~ "defmodule AshQuint.CounterTraceTest do\n"

    assert read(root, @test_file) =~
             "use AshQuint.Case, model: :counter, adapter: AshQuint.CounterTrace, sensitivity: true"
  end

  test "writes the race model's files", %{root: root} do
    gen(root, ["race"])

    assert read(root, "test/support/race_trace.ex") =~ "defmodule AshQuint.RaceTrace do\n"
    assert read(root, "test/race_trace_test.exs") =~ "defmodule AshQuint.RaceTraceTest do\n"
  end

  test "--adapter names the module", %{root: root} do
    gen(root, ["counter", "--adapter", "MyApp.Counter"])

    assert read(root, @adapter_file) =~ "defmodule MyApp.Counter do\n"
    assert read(root, @test_file) =~ "defmodule MyApp.CounterTest do\n"
    assert read(root, @test_file) =~ "adapter: MyApp.Counter,"
  end

  test "asks before overwriting", %{root: root} do
    File.mkdir_p!(Path.join(root, "test/support"))
    File.write!(Path.join(root, @adapter_file), "mine\n")

    send(self(), {:mix_shell_input, :yes?, false})
    gen(root, ["counter"])

    assert_received {:mix_shell, :yes?, [question]}
    assert question =~ @adapter_file
    assert read(root, @adapter_file) == "mine\n"
    assert read(root, @test_file) =~ "defmodule AshQuint.CounterTraceTest do\n"

    gen(root, ["counter", "--force"])
    refute_received {:mix_shell, :yes?, _question}
    assert read(root, @adapter_file) =~ "defmodule AshQuint.CounterTrace do\n"
  end

  test "refuses a format 2 manifest", %{root: root} do
    path = Path.join(root, @manifest)

    json =
      path
      |> File.read!()
      |> Jason.decode!()
      |> Map.delete("interface")
      |> Map.put("ash_quint", 2)

    File.write!(path, Jason.encode!(json))

    assert_raise Mix.Error,
                 "#{@manifest} has no model interface (manifest format 2); " <>
                   "run MIX_ENV=test mix ash_quint.gen counter",
                 fn -> gen(root, ["counter"]) end

    refute File.exists?(Path.join(root, @adapter_file))
  end

  test "a missing manifest", %{root: root} do
    File.rm!(Path.join(root, @manifest))

    assert_raise Mix.Error,
                 "no manifest for :counter at #{@manifest}; " <>
                   "run MIX_ENV=test mix ash_quint.gen counter",
                 fn -> gen(root, ["counter"]) end
  end

  test "an unknown model", %{root: root} do
    assert_raise Mix.Error, "model :nope is not configured in ash_quint.exs", fn ->
      gen(root, ["nope"])
    end
  end

  test "one model is required", %{root: root} do
    usage = "usage: mix ash_quint.gen.adapter <model> [--adapter Module] [--force]"

    assert_raise Mix.Error, usage, fn -> gen(root, []) end
    assert_raise Mix.Error, usage, fn -> gen(root, ["counter", "race"]) end
  end

  test "an unknown flag is an error", %{root: root} do
    assert_raise OptionParser.ParseError, fn -> gen(root, ["counter", "--nope"]) end
  end
end
