defmodule TimelessStack.MetricsDataPlane do
  @moduledoc """
  Compatibility adapter over the Rust metrics HTTP boundary.

  Ranking and combining series go through the plane's PromQL routes
  (`top_series/5`, `range_matched/6`); the native range route asks only
  what a label equals and cannot group or rank. The translation is
  `TimelessUI.MetricsDataPlane.PromQL`.
  """

  alias TimelessUI.MetricsDataPlane.Client
  alias TimelessUI.MetricsDataPlane.PromQL

  @doc """
  The ranked groups of `metric` at `time` (unix seconds), by an element's
  matchers. `opts`: the canvas's `top_series/5` options, plus
  `:lookback_delta` (seconds) and `:counter?` (rank by rate over the
  lookback rather than by value).
  """
  def top_series(_store, metric, matchers, time, opts) do
    inner = grouped(selected(metric, matchers, opts), opts)
    rank = if Keyword.get(opts, :order) == :asc, do: "bottomk", else: "topk"
    query = "#{rank}(#{Keyword.get(opts, :limit, 10)}, #{inner})"

    with {:ok, body} <- client().prometheus_instant(query, time, promql_opts(opts)) do
      PromQL.rows(body, Keyword.get(opts, :order, :desc))
    end
  end

  @doc """
  The series of `metric` an element's matchers select, over `from`..`to`
  (unix seconds) in steps of `opts[:step]` seconds, combined by
  `opts[:aggregate]` where there is one. Points are unix milliseconds, as
  the canvas draws them.
  """
  def range_matched(_store, metric, matchers, from, to, opts) do
    selected = selected(metric, matchers, opts)

    query =
      case Keyword.get(opts, :aggregate) do
        nil -> selected
        aggregate -> "#{aggregate}(#{selected})"
      end

    step = Keyword.get(opts, :step, 60)

    with {:ok, body} <- client().prometheus_range(query, from, to, step, promql_opts(opts)) do
      PromQL.series(body)
    end
  end

  # A counter is read as its rate over the lookback: what it rose by a
  # second, which is what a ranking or a line of it means.
  defp selected(metric, matchers, opts) do
    selector = PromQL.selector(metric, matchers)

    if Keyword.get(opts, :counter?, false),
      do: "rate(#{selector}[#{Keyword.get(opts, :lookback_delta, 30)}s])",
      else: selector
  end

  defp grouped(selected, opts) do
    aggregate = Keyword.get(opts, :aggregate, :sum)

    case Keyword.get(opts, :group_by, []) do
      [] -> selected
      keys -> "#{aggregate} by (#{Enum.join(keys, ",")}) (#{selected})"
    end
  end

  defp promql_opts(opts) do
    case Keyword.get(opts, :lookback_delta) do
      nil -> []
      seconds -> [lookback_delta: seconds]
    end
  end

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

  @doc """
  The series with `labels` that have reported in the last `window` seconds,
  in the shape of `list_series_matching/2`.

  `/api/v1/series` is every series the store has ever had with those
  labels, and a collector that gives each process series of its own makes
  that the processes there have been. A nameless instant query with the
  window as its lookback is the series there are now: what a panel lists
  to be put on a canvas.

  The plane counts the points within the lookback against its work limit,
  so a wide window over many series is refused; the caller narrows it or
  falls back to `list_series_matching/2`.
  """
  def list_series_reporting(_store, labels, window) when is_map(labels) and is_integer(window) do
    matchers = Enum.map(labels, fn {key, value} -> {key, :eq, [value]} end)
    selector = PromQL.selector("", matchers)

    with {:ok, body} <- client().prometheus_instant(selector, nil, lookback_delta: window) do
      case body do
        %{"status" => "success", "data" => %{"result" => result}} when is_list(result) ->
          normalize_matching_series(for %{"metric" => labels} <- result, do: labels)

        _other ->
          {:error, :invalid_metrics_series_response}
      end
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
