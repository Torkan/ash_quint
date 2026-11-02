# Review of spec v1

**Verdict:** changes requested

- §Key Interfaces / Mix task, D8: "Ok, let's just use ash_quint.gen then instead". This was in reply to the finding that extensions join `mix ash.codegen` by implementing `Spark.Dsl.Extension` and exporting `codegen/1`, and that ash_quint shouldn't.
