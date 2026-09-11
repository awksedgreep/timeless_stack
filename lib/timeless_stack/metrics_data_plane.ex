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

    with {:ok, step} <- bucket_step(Keyword.fetch!(opts, :bucket)),
         {:ok, %{"metric" => ^metric, "series" => series}} when is_list(series) <-
           client().range(metric, labels, from, to, step, aggregate),
         {:ok, normalized} <- normalize_range_series(series) do
      {:ok, normalized}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_metrics_range_response}
    end
  end

  def latest_multi(_store, metric, labels) do
    with {:ok, response} <- client().latest(metric, labels),
         {:ok, rows} <- normalize_latest_response(response) do
      {:ok, rows}
    end
  end

  def list_metrics(_store), do: client().label_values("__name__")

  def label_values(_store, metric, label_key) do
    client().label_values(label_key, %{"metric" => metric})
  end

  def list_label_values(_store, label_key), do: client().label_values(label_key)

  def list_series(_store, metric) do
    with {:ok, series} <- client().series(metric),
         true <- Enum.all?(series, &match?(%{"labels" => labels} when is_map(labels), &1)) do
      {:ok, Enum.map(series, fn %{"labels" => labels} -> %{labels: labels} end)}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_metrics_series_response}
    end
  end

  def list_series_matching(_store, labels) when is_map(labels) do
    with {:ok, selector} <- exact_selector(labels),
         {:ok, %{"status" => "success", "data" => series}} when is_list(series) <-
           client().request_json(:get, "/api/v1/series", params: %{"match[]" => selector}),
         {:ok, normalized} <- normalize_matching_series(series) do
      {:ok, normalized}
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

  # The external metrics plane has no separate metadata registry. Poller
  # writers preserve their source type as the `type` series label, so expose
  # that stable wire contract through the compatibility API instead.
  def get_metadata(store, metric) do
    case label_values(store, metric, "type") do
      {:ok, []} ->
        {:ok, nil}

      {:ok, values} ->
        case Enum.uniq(values) do
          [type] when is_binary(type) ->
            {:ok, %{type: type, unit: nil, description: nil}}

          types ->
            {:error, {:ambiguous_metric_type, types}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  def flush(_store), do: client().flush()
  def backup(destination), do: client().backup(destination, timeout: 300_000)
  def health, do: client().health()

  defp client do
    Application.get_env(:timeless_stack, :metrics_data_plane_client, Client)
  end

  defp bucket_step({value, :seconds}) when is_integer(value) and value > 0, do: {:ok, value}
  defp bucket_step(other), do: {:error, {:unsupported_metrics_bucket, other}}

  # Validate and transform in one pass. Range timestamps are epoch seconds by
  # both the native server API and the TimelessMetrics compatibility contract;
  # the canvas converts them to JavaScript milliseconds at its boundary.
  defp normalize_range_series(series) do
    series
    |> Enum.reduce_while({:ok, []}, fn
      %{"labels" => labels, "data" => data}, {:ok, rows}
      when is_map(labels) and is_list(data) ->
        case normalize_range_points(data) do
          {:ok, points} -> {:cont, {:ok, [%{labels: labels, data: points} | rows]}}
          :error -> {:halt, {:error, :invalid_metrics_range_response}}
        end

      _row, _acc ->
        {:halt, {:error, :invalid_metrics_range_response}}
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_range_points(data) do
    data
    |> Enum.reduce_while({:ok, []}, fn
      [timestamp, value], {:ok, points} when is_integer(timestamp) and is_number(value) ->
        {:cont, {:ok, [{timestamp, value} | points]}}

      _point, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, points} -> {:ok, Enum.reverse(points)}
      :error -> :error
    end
  end

  defp normalize_latest_response(%{"data" => rows}) when is_list(rows),
    do: normalize_latest_rows(rows)

  defp normalize_latest_response(%{"labels" => _labels} = row),
    do: normalize_latest_rows([row])

  defp normalize_latest_response(_response), do: {:error, :invalid_metrics_latest_response}

  defp normalize_latest_rows(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn
      %{"labels" => labels, "timestamp" => timestamp, "value" => value}, {:ok, acc}
      when is_map(labels) and is_integer(timestamp) and is_number(value) ->
        {:cont, {:ok, [%{labels: labels, timestamp: timestamp, value: value} | acc]}}

      _row, _acc ->
        {:halt, {:error, :invalid_metrics_latest_response}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp exact_selector(labels) do
    labels
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.reduce_while({:ok, []}, fn
      {key, value}, {:ok, matchers}
      when is_binary(key) and is_binary(value) ->
        if Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*$/, key) do
          {:cont, {:ok, [key <> "=" <> Jason.encode!(value) | matchers]}}
        else
          {:halt, {:error, {:invalid_metric_label_name, key}}}
        end

      {key, _value}, _acc ->
        {:halt, {:error, {:invalid_metric_label, key}}}
    end)
    |> case do
      {:ok, matchers} -> {:ok, "{" <> (matchers |> Enum.reverse() |> Enum.join(",")) <> "}"}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_matching_series(series) do
    series
    |> Enum.reduce_while({:ok, []}, fn
      row, {:ok, acc} when is_map(row) ->
        case Map.pop(row, "__name__") do
          {metric, labels} when is_binary(metric) and is_map(labels) ->
            {:cont, {:ok, [%{metric: metric, labels: labels} | acc]}}

          _ ->
            {:halt, {:error, :invalid_metrics_series_response}}
        end

      _row, _acc ->
        {:halt, {:error, :invalid_metrics_series_response}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end
end
