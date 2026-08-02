defmodule TimelessStack.MetricsDataPlane do
  @moduledoc "Compatibility adapter over the Rust metrics HTTP boundary."

  alias TimelessUI.MetricsDataPlane.Client

  def query_multi(_store, metric, labels, opts) do
    from = Keyword.fetch!(opts, :from)
    to = Keyword.fetch!(opts, :to)

    with {:ok, series} <- client().export(metric, labels, from, to) do
      {:ok,
       Enum.map(series, fn row ->
         %{
           row
           | points:
               Enum.map(row.points, fn {timestamp_ms, value} ->
                 {div(timestamp_ms, 1_000), value}
               end)
         }
       end)}
    end
  end

  def query_aggregate_multi(_store, metric, labels, opts) do
    from = Keyword.fetch!(opts, :from)
    to = Keyword.fetch!(opts, :to)
    aggregate = Keyword.get(opts, :aggregate, :avg)

    step =
      case Keyword.fetch!(opts, :bucket) do
        {value, :seconds} when is_integer(value) and value > 0 -> value
        other -> raise ArgumentError, "unsupported Rust data-plane bucket #{inspect(other)}"
      end

    with {:ok, %{"metric" => ^metric, "series" => series}} when is_list(series) <-
           client().range(metric, labels, from, to, step, aggregate),
         true <- Enum.all?(series, &valid_range_series?/1) do
      {:ok,
       Enum.map(series, fn %{"labels" => labels, "data" => data} ->
         %{labels: labels, data: Enum.map(data, fn [timestamp, value] -> {timestamp, value} end)}
       end)}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_metrics_range_response}
    end
  end

  def list_metrics(_store), do: client().label_values("__name__")

  def label_values(_store, metric, label_key) do
    client().label_values(label_key, %{"metric" => metric})
  end

  def list_series(_store, metric) do
    with {:ok, series} <- client().series(metric),
         true <- Enum.all?(series, &match?(%{"labels" => labels} when is_map(labels), &1)) do
      {:ok, Enum.map(series, fn %{"labels" => labels} -> %{labels: labels} end)}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_metrics_series_response}
    end
  end

  def info(_store) do
    case client().stats() do
      {:ok, stats} ->
        %{
          oldest_timestamp: stats["oldest_timestamp_seconds"],
          newest_timestamp: stats["newest_timestamp_seconds"],
          series_count: stats["series"],
          point_count: stats["total_points"],
          storage_bytes: stats["database_file_bytes"]
        }

      {:error, reason} ->
        %{error: reason, oldest_timestamp: nil, newest_timestamp: nil}
    end
  end

  def get_metadata(_store, _metric),
    do: {:error, {:unsupported_capability, :metrics_metadata_registry}}

  def flush(_store), do: client().flush()

  defp client do
    Application.get_env(:timeless_stack, :metrics_data_plane_client, Client)
  end

  defp valid_range_series?(%{"labels" => labels, "data" => data})
       when is_map(labels) and is_list(data) do
    Enum.all?(
      data,
      &match?([timestamp, value] when is_integer(timestamp) and is_number(value), &1)
    )
  end

  defp valid_range_series?(_series), do: false
end
