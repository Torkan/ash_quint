defmodule AshQuint.Test.Tracer do
  @moduledoc false
  # An Ash tracer whose span context is the calling process's :test_span
  # (process dictionary); everything else is a no-op.
  use Ash.Tracer

  @impl true
  def start_span(_type, _name), do: :ok
  @impl true
  def stop_span, do: :ok
  @impl true
  def get_span_context, do: Process.get(:test_span)
  @impl true
  def set_span_context(context) do
    Process.put(:test_span, context)
    :ok
  end

  @impl true
  def set_metadata(_type, _metadata), do: :ok
  @impl true
  def set_error(_error, _opts), do: :ok
  @impl true
  def trace_type?(_type), do: false
end
