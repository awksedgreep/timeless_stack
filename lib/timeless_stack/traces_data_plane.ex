defmodule TimelessStack.TracesDataPlane do
  @moduledoc "Compatibility adapter over the Rust traces HTTP boundary."

  @behaviour TimelessCanvas.StreamSource

  alias TimelessUI.TracesDataPlane.Client

  # The search endpoint rejects a limit above this.
  @max_page 100

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

  @doc """
  Historical spans for a canvas trace element, per `TimelessCanvas.StreamSource`.

  The timeline slider asks for a window through this callback rather than
  through the tail. It is an *optional* callback, so its absence is not a
  compile error and not a startup error — it raises inside the query task on
  the first slider drag, once per retry, which is how it presents as the whole
  interface locking up rather than as one element failing.

  The data plane's search endpoint has no attribute predicate, unlike the tail,
  so an attribute filter is applied here after the fact. To keep that from
  silently under-filling the window, the request is widened to the endpoint's
  maximum page and trimmed back afterwards; a window busy enough to overflow
  100 spans can still come back short. Giving search the same attribute filter
  the tail has would remove the compromise.
  """
  def query(filters) do
    {attributes, filters} = Keyword.pop(filters, :attributes)
    limit = Keyword.get(filters, :limit, @max_page)

    filters =
      filters
      |> Keyword.take([:name, :service, :kind, :status, :since, :until, :limit, :offset, :order])
      |> then(fn filters ->
        if attributes, do: Keyword.put(filters, :limit, @max_page), else: filters
      end)

    case client().search(filters) do
      {:ok, %{entries: entries} = result} ->
        {:ok, %{result | entries: entries |> filter_attributes(attributes) |> Enum.take(limit)}}

      {:error, _reason} = error ->
        error
    end
  end

  defp filter_attributes(entries, nil), do: entries
  defp filter_attributes(entries, attributes) when attributes == %{}, do: entries

  defp filter_attributes(entries, attributes) do
    Enum.filter(entries, fn entry ->
      Enum.all?(attributes, fn {key, value} ->
        # Compared as text, as the tail does, so a value selects the span
        # whether the exporter sent it as a number or a string.
        case Map.get(entry.attributes || %{}, key) do
          nil -> false
          actual -> to_string(actual) == to_string(value)
        end
      end)
    end)
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
