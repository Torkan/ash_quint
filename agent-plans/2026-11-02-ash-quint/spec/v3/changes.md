# Changes since v2

- **D10, model and trace locations configurable** (the Open Question is closed):
  - the top-level `model_dir` and `fixture_dir` (defaults `test/quint`, `test/fixtures/quint`) set the base directories;
  - each model's `model`, `tests` and `out` default to `<model_dir>/<name>/model.qnt`, `<model_dir>/<name>/model-tests.qnt` and `<fixture_dir>/<name>`, and each can be overridden;
  - paths are relative to the project root and must stay inside it, including git-excluded directories such as `agent-plans/`.
- **`on_missing_model: :fail | :skip`,** top-level or per model, default `:fail`: for projects whose models aren't committed. The staleness test is skipped instead of failing when a model file is missing; replays still run.
- Error Handling and Testing Strategy cover missing model files and paths outside the project.
- Addresses v2 review: "It should be configurable where the model files are stored".
