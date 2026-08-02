defmodule TimelessStack.LogsDataPlane do
  @moduledoc "Compatibility adapter over the Rust logs HTTP boundary."

  alias TimelessUI.LogsDataPlane.Client

  @metadata_keys %{"host" => :host, "service" => :service, "path" => :path, "status" => :status}

  def query(filters \\ []) do
    with {:ok, filters} <- translate_filters(filters), do: client().query(filters)
  end

  def field_values(field, filters \\ []) do
    with {:ok, filters} <- translate_filters(filters), do: client().field_values(field, filters)
  end

  def stats, do: client().stats()
  def flush, do: client().flush()

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
