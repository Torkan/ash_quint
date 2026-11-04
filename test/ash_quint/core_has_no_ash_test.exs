defmodule AshQuint.CoreHasNoAshTest do
  use ExUnit.Case, async: true

  @forbidden ["Ash", "Spark", "Splode"]

  # The package's own modules: those compiled from lib/, not test/support.
  defp core_modules do
    lib = Path.join(File.cwd!(), "lib")

    for mod <- Application.spec(:ash_quint, :modules),
        not ash_helper?(mod),
        source = mod.module_info(:compile)[:source],
        String.starts_with?(List.to_string(source), lib <> "/"),
        do: mod
  end

  # AshQuint.Ash and AshQuint.Ash.*: compiled only when Ash is loaded.
  defp ash_helper?(mod), do: match?(["AshQuint", "Ash" | _], Module.split(mod))

  defp forbidden?(mod) do
    case Module.split(mod) do
      [root | _] -> root in @forbidden
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  test "core modules don't call Ash" do
    modules = core_modules()
    assert AshQuint.ITF in modules
    assert AshQuint.Gate in modules
    refute AshQuint.Ash.Gate in modules

    calls =
      for mod <- modules,
          {:ok, {^mod, [imports: imports]}} = :beam_lib.chunks(:code.which(mod), [:imports]),
          {callee, fun, arity} <- imports,
          forbidden?(callee),
          do: {mod, Exception.format_mfa(callee, fun, arity)}

    assert calls == []
  end
end
