defmodule TimelessStack.TracesDataPlane do
  @moduledoc "Compatibility adapter over the Rust traces HTTP boundary."

  alias TimelessUI.TracesDataPlane.Client

  def stats, do: client().stats()
  def flush, do: client().flush()
  def search(filters \\ []), do: client().search(filters)
  def trace(trace_id), do: client().trace(trace_id)

  defp client do
    Application.get_env(:timeless_stack, :traces_data_plane_client, Client)
  end
end
