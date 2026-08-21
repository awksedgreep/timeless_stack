defmodule TimelessStack.TracesDataPlane do
  @moduledoc "Compatibility adapter over the Rust traces HTTP boundary."

  alias TimelessUI.TracesDataPlane.Client

  @doc """
  Live tail for a canvas trace element.

  Called from the process that will receive the spans, per
  `TimelessCanvas.StreamSource`, and delegates to the data plane's
  `/select/timeless/api/spans/tail`, which sends
  `{:timeless_traces, :span, span}` — the same shape the embedded engine
  delivered.

  Filtering happens **at the server**: the canvas filters become query
  parameters the data plane matches per subscriber before serialising
  anything. Filtering here instead would ship every span the system produces
  across the boundary only to discard most of them.
  """
  def subscribe(opts \\ []) do
    case client().tail(tail_filters(opts), self(), []) do
      {:ok, pid} ->
        # The tail owns an HTTP connection and the server unsubscribes when it
        # closes. Linking makes that happen: the manager kills this process to
        # unsubscribe, and without a link the tail would outlive it, leaking a
        # connection and a hub subscriber on every re-registration.
        Process.link(pid)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  # Canvas opts -> data plane filters. The canvas builds `:attributes` from an
  # element's host field, and passes nothing at all for a field left blank —
  # which asks for every span, not none.
  def tail_filters(opts) do
    Keyword.take(opts, [:service, :name, :kind, :status, :attributes])
  end

  def stats, do: client().stats()
  def flush, do: client().flush()
  def backup(destination), do: client().backup(destination, timeout: 300_000)
  def health, do: client().health()
  def search(filters \\ []), do: client().search(filters)
  def trace(trace_id), do: client().trace(trace_id)

  defp client do
    Application.get_env(:timeless_stack, :traces_data_plane_client, Client)
  end
end
