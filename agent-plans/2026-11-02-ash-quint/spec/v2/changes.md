# Changes since v1

- **The Mix task is renamed `mix ash_quint.gen`** (from `mix ash_quint.codegen`), throughout the spec. The `--check` and `--dry-run` flags stay aligned with `mix ash.codegen`. D8 now explains the name: "codegen" in Ash means the `mix ash.codegen` extension mechanism, which ash_quint deliberately stays out of. It also describes that mechanism correctly: extensions are found as `Spark.Dsl.Extension` modules defined in the app and in its `ash`/`spark`-dependent deps, not only those used by resources.
  - Addresses v1 review: "Ok, let's just use ash_quint.gen then instead".
