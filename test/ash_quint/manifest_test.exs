defmodule AshQuint.ManifestTest do
  use ExUnit.Case, async: true

  alias AshQuint.Interface
  alias AshQuint.Manifest

  @path "test/fixtures/quint/counter/manifest.json"

  defp entry(file, source, name, actions) do
    outcomes = %{
      "Action1" => %{"accepted" => 1},
      "Action2" => %{"rejected:x" => 1, "accepted" => 1}
    }

    %{
      file: file,
      source: source,
      name: name,
      steps: 3,
      actions: actions,
      outcomes: outcomes,
      concurrent: false,
      max_in_flight: 0
    }
  end

  @interface %Interface{
    actions: [
      %{name: "Init", picks: :unit, type: nil},
      %{name: "Inc", picks: :record, fields: [%{name: "by", type: "int"}]},
      %{name: "Reset", picks: :value, type: "str"}
    ],
    results: ["Accepted", "Rejected"],
    vars: [%{name: "counts", type: "str -> int"}]
  }

  defp manifest(traces, actions_order \\ :asc) do
    actions =
      1..40
      |> Enum.map(&{"Action#{&1}", &1})
      |> then(&if actions_order == :asc, do: &1, else: Enum.reverse(&1))
      |> Enum.into(%{})

    %Manifest{
      interface: @interface,
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
    assert String.starts_with?(a, "{\n  \"ash_quint\": 3,\n  \"interface\": {\n")
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
             ~r/"actions": \{\n.*\n      \},\n      "file": "random_0.itf.json",\n      "name": "0",\n      "outcomes": \{\n.*\n      \},\n      "source": "random",\n      "steps": 3\n    \}/s

    assert a =~
             ~s("Action2": {\n          "accepted": 1,\n          "rejected:x": 1\n        })
  end

  test "refuses to encode an entry without outcomes" do
    manifest = manifest([hd(@entries)])
    manifest = %{manifest | traces: Enum.map(manifest.traces, &%{&1 | outcomes: nil})}

    assert_raise ArgumentError, "manifest entry scenario_incTest.itf.json has no outcomes", fn ->
      Manifest.encode(manifest)
    end
  end

  test "round-trips with an interface" do
    manifest = %{manifest(@entries) | traces: Enum.sort_by(manifest(@entries).traces, & &1.file)}

    assert %Manifest{version: 3, interface: @interface} =
             decoded = Manifest.decode!(Manifest.encode(manifest), @path)

    assert decoded == manifest
  end

  test "encodes the interface with sorted keys" do
    encoded = Manifest.encode(manifest(@entries))

    assert encoded =~
             ~s("interface": {\n    "actions": [\n      {\n        "name": "Init",\n) <>
               ~s(        "picks": "unit"\n      },)

    assert encoded =~
             ~s(\n    ],\n    "results": [\n      "Accepted",\n      "Rejected"\n    ],\n)

    assert encoded =~ ~s(\n    "vars": [\n      {\n        "name": "counts",\n)
    assert encoded =~ ~s(\n  },\n  "models": {\n)
  end

  test "round-trips a regression entry with its seed" do
    manifest = manifest([{"regression_4031_2.itf.json", :regression, "4031_2"}])
    manifest = %{manifest | traces: Enum.map(manifest.traces, &Map.put(&1, :seed, 4031))}

    assert %Manifest{traces: [%{source: :regression, name: "4031_2", seed: 4031}]} =
             decoded = Manifest.decode!(Manifest.encode(manifest), @path)

    assert decoded == manifest
  end

  test "writes seed only for entries that have one" do
    manifest = manifest([hd(@entries), {"regression_4031_2.itf.json", :regression, "4031_2"}])

    traces =
      Enum.map(manifest.traces, fn
        %{source: :regression} = entry -> Map.put(entry, :seed, 4031)
        entry -> entry
      end)

    encoded = Manifest.encode(%{manifest | traces: traces})

    assert encoded =~
             ~r/"name": "4031_2",\n      "outcomes": \{\n.*\n      \},\n      "seed": 4031,\n      "source": "regression",\n/s

    assert length(Regex.scan(~r/"seed"/, encoded)) == 2

    assert [%{source: :regression, seed: 4031}, scenario] =
             Manifest.decode!(encoded, @path).traces

    refute Map.has_key?(scenario, :seed)
  end

  test "refuses a non-integer seed" do
    trace = %{
      "file" => "regression_4031_2.itf.json",
      "source" => "regression",
      "name" => "4031_2",
      "steps" => 2,
      "actions" => %{"Inc" => 1},
      "outcomes" => %{"Inc" => %{"accepted" => 1}}
    }

    for seed <- ["4031", 1.5, nil] do
      assert_raise ArgumentError,
                   "#{@path}: invalid manifest: seed of regression_4031_2.itf.json must be " <>
                     "an integer",
                   fn ->
                     Manifest.decode!(
                       json(%{"traces" => [Map.put(trace, "seed", seed)]}),
                       @path
                     )
                   end
    end
  end

  test "refuses to encode without an interface" do
    assert_raise ArgumentError, "manifest has no interface", fn ->
      Manifest.encode(%{manifest(@entries) | interface: nil})
    end
  end

  test "a version 3 manifest needs an interface" do
    assert_raise ArgumentError, "#{@path}: invalid manifest: interface must be an object", fn ->
      Manifest.decode!(json(%{"ash_quint" => 3}), @path)
    end

    assert_raise ArgumentError,
                 "#{@path}: invalid manifest: interface.actions[0].picks must be one of " <>
                   "map, record, unit, value",
                 fn ->
                   interface = %{
                     "actions" => [%{"name" => "A", "picks" => "x"}],
                     "results" => nil,
                     "vars" => []
                   }

                   Manifest.decode!(json(%{"ash_quint" => 3, "interface" => interface}), @path)
                 end
  end

  test "writes concurrent and max_in_flight only for concurrent traces" do
    manifest = manifest(@entries)
    [first | rest] = Enum.sort_by(manifest.traces, & &1.file)
    concurrent = %{first | concurrent: true, max_in_flight: 2}
    manifest = %{manifest | traces: [concurrent | rest]}
    encoded = Manifest.encode(manifest)

    assert encoded =~
             ~r/"concurrent": true,\n      "file": "random_0.itf.json",\n      "max_in_flight": 2,\n/

    assert length(Regex.scan(~r/"concurrent"/, encoded)) == 1
    refute encoded =~ "max_in_flight\": 0"
    assert Manifest.decode!(encoded, @path) == manifest
  end

  test "reads entries without the concurrency keys as sequential" do
    assert %Manifest{traces: [entry]} = Manifest.decode!(json(%{}), @path)
    assert %{concurrent: false, max_in_flight: 0} = entry
  end

  test "refuses malformed concurrency keys" do
    trace = %{
      "file" => "random_0.itf.json",
      "source" => "random",
      "name" => "0",
      "steps" => 2,
      "actions" => %{"Inc" => 1},
      "outcomes" => %{"Inc" => %{"accepted" => 1}}
    }

    for keys <- [
          %{"concurrent" => true},
          %{"concurrent" => false, "max_in_flight" => 1},
          %{"concurrent" => "yes", "max_in_flight" => 1},
          %{"concurrent" => true, "max_in_flight" => 0},
          %{"max_in_flight" => 2}
        ] do
      assert_raise ArgumentError,
                   "#{@path}: invalid manifest: concurrent and max_in_flight of " <>
                     "random_0.itf.json must be absent, or true and a positive integer",
                   fn ->
                     Manifest.decode!(json(%{"traces" => [Map.merge(trace, keys)]}), @path)
                   end
    end
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
      "ash_quint" => 2,
      "quint" => "0.33.1",
      "seed" => 1,
      "models" => %{"m.qnt" => "sha256:aa"},
      "traces" => [
        %{
          "file" => "random_0.itf.json",
          "source" => "random",
          "name" => "0",
          "steps" => 2,
          "actions" => %{"Init" => 1, "Inc" => 1},
          "outcomes" => %{"Inc" => %{"accepted" => 1}}
        }
      ]
    }
    |> Map.merge(overrides)
    |> Jason.encode!()
  end

  describe "backend" do
    test "encode/1 writes backend when set" do
      json = Jason.decode!(Manifest.encode(%{manifest(@entries) | backend: "rust"}))

      assert json["backend"] == "rust"
      assert json["ash_quint"] == 3
    end

    test "encode/1 omits backend when unset" do
      refute Map.has_key?(Jason.decode!(Manifest.encode(manifest(@entries))), "backend")
    end

    test "decode!/2 round-trips backend" do
      encoded = Manifest.encode(%{manifest(@entries) | backend: "rust"})

      assert Manifest.decode!(encoded, @path).backend == "rust"
      assert Manifest.decode!(Manifest.encode(manifest(@entries)), @path).backend == nil
      assert Manifest.decode!(json(%{"backend" => "typescript"}), @path).backend == "typescript"
      assert Manifest.decode!(json(%{}), @path).backend == nil
    end

    test "decode!/2 refuses a non-string backend" do
      assert_raise ArgumentError, "#{@path}: invalid manifest: backend must be a string", fn ->
        Manifest.decode!(json(%{"backend" => 1}), @path)
      end

      assert_raise ArgumentError, "#{@path}: invalid manifest: backend must be a string", fn ->
        Manifest.decode!(json(%{"backend" => nil}), @path)
      end
    end
  end

  test "decodes a version 2 manifest with outcomes" do
    manifest = Manifest.decode!(json(%{}), @path)

    assert manifest.version == 2
    assert manifest.interface == nil
    assert [%{outcomes: %{"Inc" => %{"accepted" => 1}}}] = manifest.traces
  end

  test "decodes a version 1 manifest, without outcomes" do
    traces = [
      %{
        "file" => "random_0.itf.json",
        "source" => "random",
        "name" => "0",
        "steps" => 1,
        "actions" => %{"Inc" => 1}
      }
    ]

    manifest = Manifest.decode!(json(%{"ash_quint" => 1, "traces" => traces}), @path)

    assert manifest.version == 1
    assert manifest.interface == nil
    assert [%{actions: %{"Inc" => 1}, outcomes: nil}] = manifest.traces
  end

  test "refuses a version from a newer ash_quint" do
    assert_raise ArgumentError,
                 "#{@path}: written by a newer ash_quint (manifest format 4; " <>
                   "this version reads formats 1 to 3); upgrade ash_quint",
                 fn -> Manifest.decode!(json(%{"ash_quint" => 4}), @path) end
  end

  test "refuses an unknown version" do
    for version <- [0, "3"] do
      assert_raise ArgumentError,
                   "#{@path}: unsupported manifest version #{inspect(version)}",
                   fn -> Manifest.decode!(json(%{"ash_quint" => version}), @path) end
    end
  end

  test "refuses two entries for the same file" do
    entry = %{
      "file" => "random_0.itf.json",
      "source" => "random",
      "name" => "0",
      "steps" => 1,
      "actions" => %{"Inc" => 1},
      "outcomes" => %{}
    }

    assert_raise ArgumentError,
                 "#{@path}: invalid manifest: more than one entry for random_0.itf.json",
                 fn -> Manifest.decode!(json(%{"traces" => [entry, entry]}), @path) end
  end

  test "a version 2 entry needs well-formed outcomes" do
    entry = %{
      "file" => "random_0.itf.json",
      "source" => "random",
      "name" => "0",
      "steps" => 1,
      "actions" => %{"Inc" => 1}
    }

    assert_raise ArgumentError, "#{@path}: invalid manifest: traces[0] is malformed", fn ->
      Manifest.decode!(json(%{"traces" => [entry]}), @path)
    end

    for outcomes <- [%{"Inc" => %{"accepted" => 0}}, %{"Inc" => 1}, []] do
      assert_raise ArgumentError,
                   "#{@path}: invalid manifest: outcomes of random_0.itf.json must map " <>
                     "actions to maps of labels to positive integers",
                   fn ->
                     Manifest.decode!(
                       json(%{"traces" => [Map.put(entry, "outcomes", outcomes)]}),
                       @path
                     )
                   end
    end
  end

  test "refuses an unknown source" do
    traces = [
      %{
        "file" => "fuzz_0.itf.json",
        "source" => "fuzz",
        "name" => "0",
        "steps" => 2,
        "actions" => %{},
        "outcomes" => %{}
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
        "actions" => %{"Inc" => 0},
        "outcomes" => %{}
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
