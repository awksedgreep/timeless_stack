defmodule TimelessStack.UIDataSource do
  @moduledoc """
  DataSource implementation that wires TimelessUI canvas elements to
  real TimelessMetrics, TimelessLogs, and TimelessTraces data.

  Configured via:

      config :timeless_canvas, :data_source,
        module: TimelessStack.UIDataSource,
        config: %{metrics_store: :timeless_metrics},
        poll_interval: 5_000
  """

  @behaviour TimelessCanvas.DataSource

  alias TimelessStack.UIDataSource.Cache

  @impl true
  def init(config) do
    store = Map.get(config, :metrics_store, :timeless_metrics)
    metrics_module = Map.get(config, :metrics_module, configured_metrics_module())
    cache_name = Map.get(config, :cache_name, Cache)
    cache_table = Map.get(config, :cache_table, Cache.default_table())

    {:ok,
     %{
       store: store,
       metrics_module: metrics_module,
       cache_name: cache_name,
       cache_table: cache_table
     }}
  end

  @impl true
  def status(_state, element) do
    case status_host(element) do
      nil ->
        :unknown

      host ->
        since = DateTime.add(DateTime.utc_now(), -60, :second)
        check_logs_for_status(host, since: since)
    end
  end

  @impl true
  def metric(state, element, metric_name) do
    labels = build_labels(element)

    case state.metrics_module.query_multi(state.store, metric_name, labels,
           from: DateTime.to_unix(DateTime.add(DateTime.utc_now(), -300, :second)),
           to: DateTime.to_unix(DateTime.utc_now())
         ) do
      {:ok, [%{points: [_ | _] = points} | _]} ->
        {_ts, value} = List.last(points)
        {:ok, value}

      _ ->
        :no_data
    end
  end

  @impl true
  def subscribe(state, _element), do: {:ok, state}

  @impl true
  def unsubscribe(state, _element), do: {:ok, state}

  @impl true
  def handle_message(_state, _msg), do: :ignore

  @impl true
  def metric_at(state, element, metric_name, %DateTime{} = time) do
    labels = build_labels(element)
    from = DateTime.to_unix(DateTime.add(time, -5, :second))
    to = DateTime.to_unix(time)

    case state.metrics_module.query_multi(state.store, metric_name, labels, from: from, to: to) do
      {:ok, [%{points: [_ | _] = points} | _]} ->
        {_ts, value} = List.last(points)
        {:ok, value}

      _ ->
        :no_data
    end
  end

  @impl true
  def metric_range(state, element, metric_name, %DateTime{} = from, %DateTime{} = to) do
    labels = build_labels(element)
    from_ts = DateTime.to_unix(from)
    to_ts = DateTime.to_unix(to)
    bucket_seconds = graph_bucket_seconds(from_ts, to_ts)
    {from_ts, to_ts} = align_graph_window(from_ts, to_ts, bucket_seconds)

    if counter_metric?(state, element, metric_name) do
      counter_metric_range(state, metric_name, labels, from_ts, to_ts, bucket_seconds)
    else
      gauge_metric_range(state, metric_name, labels, from_ts, to_ts, bucket_seconds)
    end
  end

  @impl true
  def status_at(_state, element, %DateTime{} = time) do
    case extract_host(element) do
      nil ->
        :unknown

      host ->
        since = DateTime.add(time, -60, :second)
        check_logs_for_status(host, since: since, until: time)
    end
  end

  @impl true
  def time_range(state) do
    info = state.metrics_module.info(state.store)

    case {info[:oldest_timestamp], info[:newest_timestamp]} do
      {nil, _} ->
        :empty

      {_, nil} ->
        :empty

      {oldest, newest} ->
        with {:ok, oldest_dt} <- safe_from_unix(oldest),
             {:ok, newest_dt} <- safe_from_unix(newest) do
          {oldest_dt, newest_dt}
        else
          _ -> :empty
        end
    end
  end

  # Timestamps > 1e12 are likely milliseconds; convert to seconds.
  # Also handles floats by truncating.
  defp safe_from_unix(ts) when is_number(ts) do
    ts = if is_float(ts), do: trunc(ts), else: ts
    ts = if ts > 1_000_000_000_000, do: div(ts, 1_000), else: ts
    DateTime.from_unix(ts)
  end

  defp safe_from_unix(_), do: {:error, :invalid}

  defp graph_bucket_seconds(from_ts, to_ts) do
    range_seconds = max(to_ts - from_ts, 1)
    max(div(range_seconds, 60), 1)
  end

  defp align_graph_window(from_ts, to_ts, bucket_seconds) do
    span_seconds = max(to_ts - from_ts, 1)
    aligned_to = div(to_ts, bucket_seconds) * bucket_seconds
    {aligned_to - span_seconds, aligned_to}
  end

  @impl true
  def list_hosts(state, opts \\ []) do
    read_cached(state, {:label_values, "host"}, opts, fn host -> host end)
  end

  @impl true
  def list_series_for_host(state, host, opts \\ []) do
    read_cached(state, {:host_series, host}, opts, fn {metric_name, _labels} -> metric_name end)
  end

  @impl true
  def series_loaded?(state, host) do
    # A cold miss and a host with no series both read as an empty list. The
    # cache is the only thing that knows which one this is.
    Cache.get(state.cache_table, {:host_series, host}) != :miss
  end

  @impl true
  def metric_metadata(state, metric_name) do
    state.metrics_module.get_metadata(state.store, metric_name)
  end

  @impl true
  def list_label_values(state, label_key, opts \\ []) do
    read_cached(state, {:label_values, label_key}, opts, fn value -> value end)
  end

  @impl true
  def statuses(state, elements) do
    since = DateTime.add(DateTime.utc_now(), -60, :second)
    batch_statuses(state, elements, &status_host/1, since: since)
  end

  @impl true
  def statuses_at(state, elements, %DateTime{} = time) do
    since = DateTime.add(time, -60, :second)
    batch_statuses(state, elements, &extract_host/1, since: since, until: time)
  end

  # --- Private ---

  # Reads only from the ETS cache maintained by
  # `TimelessStack.UIDataSource.Cache` — never enumerates the store on
  # the request path. A miss (cold cache) returns `[]` and the async
  # `ensure/2` cast triggers a background fetch/refresh.
  defp read_cached(state, key, opts, name_fun) do
    Cache.ensure(state.cache_name, key)

    case Cache.get(state.cache_table, key) do
      {:ok, values} -> TimelessCanvas.DataSource.apply_query_opts(values, opts, name_fun)
      :miss -> []
    end
  end

  # One grouped logs query per level (via `field_values/2`) covers every
  # host in the batch, replacing up to 2 queries per host element.
  defp batch_statuses(_state, elements, host_fun, window) do
    host_by_element = Map.new(elements, fn element -> {element.id, host_fun.(element)} end)
    any_host? = Enum.any?(host_by_element, fn {_id, host} -> not is_nil(host) end)

    {error_hosts, warning_hosts} =
      if any_host? do
        {hosts_with_level(:error, window), hosts_with_level(:warning, window)}
      else
        {MapSet.new(), MapSet.new()}
      end

    Map.new(host_by_element, fn
      {id, nil} ->
        {id, :unknown}

      {id, host} ->
        cond do
          MapSet.member?(error_hosts, host) -> {id, :error}
          MapSet.member?(warning_hosts, host) -> {id, :warning}
          true -> {id, :ok}
        end
    end)
  end

  defp hosts_with_level(level, window) do
    since_dt = Keyword.fetch!(window, :since)
    until_dt = Keyword.get(window, :until)

    filters = [level: level, since: DateTime.to_unix(since_dt)]

    filters =
      if until_dt,
        do: Keyword.put(filters, :until, DateTime.to_unix(until_dt)),
        else: filters

    case logs_mod().field_values("host", filters) do
      {:ok, values} -> MapSet.new(values, fn %{"value" => value} -> value end)
      _ -> MapSet.new()
    end
  end

  defp logs_mod do
    Application.get_env(:timeless_stack, :timeless_logs_module, TimelessLogs)
  end

  defp extract_host(element) do
    meta = element.meta || %{}
    meta["host"] || meta["service_name"]
  end

  defp status_host(%{type: type} = _element)
       when type in [:graph, :text_series, :log_stream, :trace_stream, :canvas, :text, :rect] do
    nil
  end

  defp status_host(element), do: extract_host(element)

  @doc """
  The label filter an element's queries use.

  Public so alert rules can be scoped by exactly what draws the graph. If a
  rule derived its own labels, it could watch a different series than the
  picture it was created from and look correct doing it.
  """
  def element_labels(element), do: build_labels(element)

  defp build_labels(element) do
    meta = element.meta || %{}
    series_label_key = meta["series_label_key"]
    series_label_value = meta["series_label_value"]

    series_filter =
      if is_binary(series_label_key) and series_label_key != "" and
           is_binary(series_label_value) and series_label_value != "" do
        %{series_label_key => series_label_value}
      else
        %{}
      end

    meta
    |> Map.drop([
      "metric_name",
      "series_label_key",
      "series_label_value",
      "y_min",
      "y_max",
      "icon",
      "os_icon"
    ])
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
    |> Map.merge(series_filter)
  end

  defp gauge_metric_range(state, metric_name, labels, from_ts, to_ts, bucket_seconds) do
    case state.metrics_module.query_aggregate_multi(state.store, metric_name, labels,
           from: from_ts,
           to: to_ts,
           bucket: {bucket_seconds, :seconds},
           aggregate: :last
         ) do
      {:ok, [%{data: points} | _]} ->
        {:ok, Enum.map(points, fn {ts, val} -> {ts * 1000, val} end)}

      _ ->
        {:ok, []}
    end
  end

  defp counter_metric_range(state, metric_name, labels, from_ts, to_ts, bucket_seconds) do
    case state.metrics_module.query_aggregate_multi(state.store, metric_name, labels,
           from: from_ts,
           to: to_ts,
           bucket: {bucket_seconds, :seconds},
           aggregate: :last
         ) do
      {:ok, [%{data: points} | _]} ->
        {:ok, points |> bucket_rates() |> Enum.map(fn {ts, val} -> {ts * 1000, val} end)}

      _ ->
        {:ok, []}
    end
  end

  defp bucket_rates(points) when length(points) < 2, do: []

  defp bucket_rates(points) do
    points
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [{t1, v1}, {t2, v2}] ->
      dt = t2 - t1
      dv = v2 - v1

      if dt > 0 and dv >= 0 do
        [{t2, dv / dt}]
      else
        []
      end
    end)
  end

  defp counter_metric?(state, %{meta: meta}, metric_name) when is_map(meta) do
    case Map.get(meta, "type") do
      type when type in ["counter32", "counter64"] ->
        true

      _ ->
        counter_metric_from_metadata?(state, metric_name)
    end
  end

  defp counter_metric?(state, _element, metric_name) do
    counter_metric_from_metadata?(state, metric_name)
  end

  defp counter_metric_from_metadata?(state, metric_name) do
    case state.metrics_module.get_metadata(state.store, metric_name) do
      {:ok, %{type: type}} when type in ["counter32", "counter64", :counter32, :counter64] ->
        true

      _ ->
        false
    end
  end

  defp check_logs_for_status(host, opts) do
    since_dt = Keyword.fetch!(opts, :since)
    until_dt = Keyword.get(opts, :until)

    base_filters = [
      metadata: %{"host" => host},
      since: DateTime.to_unix(since_dt),
      limit: 1
    ]

    base_filters =
      if until_dt,
        do: Keyword.put(base_filters, :until, DateTime.to_unix(until_dt)),
        else: base_filters

    # Check for errors first
    case logs_mod().query([{:level, :error} | base_filters]) do
      {:ok, %{entries: [_ | _]}} ->
        :error

      _ ->
        # Check for warnings
        case logs_mod().query([{:level, :warning} | base_filters]) do
          {:ok, %{entries: [_ | _]}} -> :warning
          _ -> :ok
        end
    end
  end

  defp configured_metrics_module do
    Application.get_env(:timeless_stack, :timeless_metrics_module, TimelessMetrics)
  end
end
