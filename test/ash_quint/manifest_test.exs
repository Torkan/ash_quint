defmodule AshQuint.ManifestTest do
  use ExUnit.Case, async: true

  alias AshQuint.Manifest

  @path "test/fixtures/quint/counter/manifest.json"

  defp entry(file, source, name, actions) do
    %{file: file, source: source, name: name, steps: 3, actions: actions}
  end

  defp manifest(traces, actions_order \\ :asc) do
    actions =
      1..40
      |> Enum.map(&{"Action#{&1}", &1})
      |> then(&if actions_order == :asc, do: &1, else: Enum.reverse(&1))
      |> Enum.into(%{})

    %Manifest{
      quint: "0.33.1",
      seed: 20_261_102,
      models: %{
        "test/quint/counter/model.qnt" => "sha256:aa",
        "test/quint/counter/model-tests.qnt" => "sha256:bb"
      },
      traces: Enum.map(traces, fn {file, source, name} -> entry(file, source, name, actions) end)
    }
  end

  @entries [
    {"scenario_incTest.itf.json", :scenario, "incTest"},
    {"random_0.itf.json", :random, "0"},
    {"witness_witMax.itf.json", :witness, "witMax"}
  ]

  test "encodes deterministically with sorted keys and traces" do
    a = Manifest.encode(manifest(@entries))
    b = Manifest.encode(manifest(Enum.reverse(@entries), :desc))

    assert a == b
    assert String.starts_with?(a, "{\n  \"ash_quint\": 1,\n  \"models\": {\n")
    assert String.ends_with?(a, "\n}\n")

    files = Regex.scan(~r/"file": "([^"]+)"/, a, capture: :all_but_first)

    assert files == [
             ["random_0.itf.json"],
             ["scenario_incTest.itf.json"],
             ["witness_witMax.itf.json"]
           ]

    actions = Regex.scan(~r/"(Action\d+)": /, a, capture: :all_but_first)
    first_trace = actions |> Enum.take(40) |> List.flatten()
    assert first_trace == Enum.sort(first_trace)

    assert a =~
             ~s("models": {\n    "test/quint/counter/model-tests.qnt": "sha256:bb",\n    "test/quint/counter/model.qnt": "sha256:aa"\n  },)

    assert a =~
             ~r/"actions": \{\n.*\n      \},\n      "file": "random_0.itf.json",\n      "name": "0",\n      "source": "random",\n      "steps": 3\n    \}/s
  end

  test "round-trips" do
    manifest = %{manifest(@entries) | traces: Enum.sort_by(manifest(@entries).traces, & &1.file)}

    assert Manifest.decode!(Manifest.encode(manifest), @path) == manifest
  end

  @tag :tmp_dir
  test "read! reads a file", %{tmp_dir: tmp_dir} do
    manifest = %{manifest([]) | traces: []}
    path = Path.join(tmp_dir, "manifest.json")
    File.write!(path, Manifest.encode(manifest))

    assert Manifest.read!(path) == manifest
  end

  @tag :tmp_dir
  test "read! lets a missing file raise File.Error", %{tmp_dir: tmp_dir} do
    assert_raise File.Error, fn -> Manifest.read!(Path.join(tmp_dir, "manifest.json")) end
  end

  @tag :tmp_dir
  test "hashes files", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "abc")
    File.write!(path, "abc")

    assert Manifest.hash_file(path) ==
             "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  end

  defp json(overrides) do
    %{
      "ash_quint" => 1,
      "quint" => "0.33.1",
      "seed" => 1,
      "models" => %{"m.qnt" => "sha256:aa"},
      "traces" => [
        %{
          "file" => "random_0.itf.json",
          "source" => "random",
          "name" => "0",
          "steps" => 2,
          "actions" => %{"Init" => 1, "Inc" => 1}
        }
      ]
    }
    |> Map.merge(overrides)
    |> Jason.encode!()
  end

  test "refuses an unknown version" do
    assert_raise ArgumentError, "#{@path}: unsupported manifest version 2", fn ->
      Manifest.decode!(json(%{"ash_quint" => 2}), @path)
    end
  end

  test "refuses an unknown source" do
    traces = [
      %{
        "file" => "fuzz_0.itf.json",
        "source" => "fuzz",
        "name" => "0",
        "steps" => 2,
        "actions" => %{}
      }
    ]

    assert_raise ArgumentError,
                 "#{@path}: unknown source \"fuzz\" for trace fuzz_0.itf.json",
                 fn -> Manifest.decode!(json(%{"traces" => traces}), @path) end
  end

  test "refuses malformed JSON" do
    assert_raise ArgumentError, ~r/^#{@path}: invalid JSON: /, fn ->
      Manifest.decode!("{", @path)
    end
  end

  test "refuses a manifest of the wrong shape" do
    assert_raise ArgumentError, "#{@path}: not an ash_quint manifest", fn ->
      Manifest.decode!(~s([1]), @path)
    end

    assert_raise ArgumentError, "#{@path}: invalid manifest: seed must be an integer", fn ->
      Manifest.decode!(json(%{"seed" => "1"}), @path)
    end

    bad_actions = [
      %{
        "file" => "random_0.itf.json",
        "source" => "random",
        "name" => "0",
        "steps" => 2,
        "actions" => %{"Inc" => 0}
      }
    ]

    assert_raise ArgumentError,
                 "#{@path}: invalid manifest: actions of random_0.itf.json " <>
                   "must map names to positive integers",
                 fn -> Manifest.decode!(json(%{"traces" => bad_actions}), @path) end

    assert_raise ArgumentError, "#{@path}: invalid manifest: traces[0] is malformed", fn ->
      Manifest.decode!(json(%{"traces" => [%{"file" => "x"}]}), @path)
    end
  end
end
