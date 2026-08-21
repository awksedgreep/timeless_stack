defmodule TimelessStack.LogsDataPlane do
  @moduledoc "Compatibility adapter over the Rust logs HTTP boundary."

  alias TimelessUI.LogsDataPlane.Client

  @metadata_keys %{"host" => :host, "service" => :service, "path" => :path, "status" => :status}

  @doc """
  Live tail for a canvas log element.

  Called from the process that will receive the entries, per
  `TimelessCanvas.StreamSource`, and delegates to the data plane's
  `/select/logsql/tail`, which sends `{:timeless_logs, :entry, entry}` — the
  same shape the embedded engine delivered.

  Filtering happens **at the server**: the canvas filters become one LogsQL
  expression which the data plane compiles into a predicate and evaluates per
  subscriber before serialising anything. Filtering here instead would ship
  every log line on the host across the boundary only to discard most of them.
  """
  def subscribe(opts \\ []) do
    case client().tail(logsql_query(opts), self(), []) do
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
  # Canvas filters -> one LogsQL expression. No filters means everything, which
  # is what an element with its host cleared is asking for.
  def logsql_query(opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    terms =
      Enum.map(metadata, fn {field, value} -> ~s(#{field}:#{quote_value(value)}) end) ++
        case Keyword.get(opts, :level) do
          nil -> []
          level -> [~s(level:#{quote_value(level)})]
        end

    case terms do
      [] -> "*"
      terms -> Enum.join(terms, " AND ")
    end
  end

  # Values are quoted unconditionally. Hostnames carry dots and dashes, and a
  # bare token would either fail to parse or silently match something else.
  defp quote_value(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace(~s("), ~s(\\"))

    ~s("#{escaped}")
  end

  def query(filters \\ []) do
    with {:ok, filters} <- translate_filters(filters), do: client().query(filters)
  end

  def field_values(field, filters \\ []) do
    with {:ok, filters} <- translate_filters(filters), do: client().field_values(field, filters)
  end

  def stats, do: client().stats()
  def flush, do: client().flush()
  def backup(destination), do: client().backup(destination, timeout: 300_000)
  def health, do: client().health()

  def ingest(entries) when is_list(entries), do: client().ingest(entries)

  defp client do
    Application.get_env(:timeless_stack, :logs_data_plane_client, Client)
  end

  defp translate_filters(filters) do
    {metadata, filters} = Keyword.pop(filters, :metadata, %{})

    with true <- is_map(metadata) || {:error, {:unsupported_capability, :logs_metadata_filter}},
         [] <- Map.keys(metadata) -- Map.keys(@metadata_keys) do
      translated =
        Enum.reduce(metadata, filters, fn {key, value}, result ->
          Keyword.put(result, Map.fetch!(@metadata_keys, key), value)
        end)

      {:ok,
       Enum.map(translated, fn {key, value} -> {translate_key(key), translate_value(value)} end)}
    else
      {:error, _reason} = error -> error
      unknown -> {:error, {:unsupported_capability, :logs_metadata_filters, unknown}}
    end
  end

  defp translate_key(:since), do: :start
  defp translate_key(:until), do: :end
  defp translate_key(key), do: key

  defp translate_value(%DateTime{} = value), do: DateTime.to_unix(value)
  defp translate_value(value), do: value
end
