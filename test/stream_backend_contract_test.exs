defmodule TimelessStack.StreamBackendContractTest do
  @moduledoc """
  Both canvas stream backends must export everything the canvas calls.

  `TimelessCanvas.StreamSource` marks `query/1` optional, so a backend without
  it is neither a compile error nor a startup error. It raises inside the query
  task the first time someone drags the timeline, and the task retries about
  once a second -- which presents as the whole interface locking up rather than
  as one element failing. That is what happened when the trace backend was
  repointed at an adapter that had `subscribe/1` but not `query/1`.
  """
  use ExUnit.Case, async: true

  @backends [TimelessStack.LogsDataPlane, TimelessStack.TracesDataPlane]

  setup_all do
    # function_exported?/3 answers false for a module that is merely not
    # loaded yet, which would make these pass for the wrong reason.
    Enum.each(@backends, &Code.ensure_loaded!/1)
    :ok
  end

  for backend <- @backends do
    test "#{inspect(backend)} subscribes for live data" do
      assert function_exported?(unquote(backend), :subscribe, 1)
    end

    test "#{inspect(backend)} answers historical queries for the timeline" do
      assert function_exported?(unquote(backend), :query, 1),
             "#{inspect(unquote(backend))} is missing query/1; the timeline slider will crash"
    end
  end
end
