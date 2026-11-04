# Used by "mix format"
[
  import_deps: [:ash],
  # ash_postgres's DSL (test/support/postgres); it is a test-only dependency,
  # so mix format (in dev) can't import its formatter config.
  locals_without_parens: [table: 1, repo: 1],
  inputs: ["{mix,.formatter,ash_quint}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
