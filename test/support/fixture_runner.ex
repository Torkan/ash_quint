defmodule AshQuint.Test.FixtureRunner do
  @moduledoc false
  # A Quint runner for explore sessions (AshQuint.Explore.run/3's :runner)
  # that runs no Quint.

  @doc """
  A runner that writes the fixture traces matching `glob`, cyclically, as
  the batch's explore_<i>.itf.json files, sends `{:quint, args, opts}` to
  the calling process and prints `output`.
  """
  def runner(glob, output \\ "") do
    fixtures = glob |> Path.wildcard() |> Enum.sort()
    test = self()

    fn _exe, args, opts ->
      send(test, {:quint, args, opts})
      "--out-itf=" <> out = Enum.find(args, &String.starts_with?(&1, "--out-itf="))
      "--n-traces=" <> n = Enum.find(args, &String.starts_with?(&1, "--n-traces="))

      fixtures
      |> Stream.cycle()
      |> Enum.take(String.to_integer(n))
      |> Enum.with_index()
      |> Enum.each(fn {fixture, i} ->
        File.cp!(fixture, String.replace(out, "{seq}", Integer.to_string(i)))
      end)

      {output, 0}
    end
  end
end
