defmodule TimelessStack.UIDataSource do
  @moduledoc """
  DataSource implementation that wires TimelessUI canvas elements to
  real TimelessMetrics, TimelessLogs, and TimelessTraces data.

  Configured via:

      config :timeless_canvas, :data_source,
        module: TimelessStack.UIDataSource,
        config: %{metrics_store: :timeless_metrics},
        poll_interval: 5_000

  ## Ranking and combining series

  `top_series/5` and `metric_range/6` are what offer the canvas its `top_n`
  element and its graph aggregate. Through the Rust plane they are PromQL
  queries; through `TimelessMetrics` in the node they are read per series
  and combined here.

  Both read at most `:lookback_seconds` back for a series' present value
  (default 30, or `config :timeless_stack, :canvas_lookback_seconds`)
  unless the element sets a `window`. A store's own lookback is often five
  minutes, which counts a process for five minutes after it has ended.
  """

  @behaviour TimelessCanvas.DataSource

  alias TimelessCanvas.Canvas.Element
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
       cache_table: cache_table,
       metadata_ttl: Map.get(config, :metadata_ttl, 60_000),
       lookback_seconds:
         Map.get(
           config,
           :lookback_seconds,
           Application.get_env(:timeless_stack, :canvas_lookback_seconds, 30)
         )
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

    case latest_metric(state, metric_name, labels) do
      {:ok, [%{value: value} | _]} ->
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

    case state.metrics_module.query_aggregate_multi(state.store, metric_name, labels,
           from: from,
           to: to,
           bucket: {5, :seconds},
           aggregate: :last
         ) do
      {:ok, [%{data: [_ | _] = points} | _]} ->
        {_timestamp, value} = List.last(points)
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
  def metric_range(state, element, metric_name, %DateTime{} = from, %DateTime{} = to, opts) do
    matchers = Element.query_matchers(element)
    from_ts = DateTime.to_unix(from)
    to_ts = DateTime.to_unix(to)
    bucket_seconds = graph_bucket_seconds(from_ts, to_ts)
    {from_ts, to_ts} = align_graph_window(from_ts, to_ts, bucket_seconds)
    counter? = counter_metric?(state, element, metric_name)

    query_opts = [
      aggregate: opts[:aggregate],
      lookback_delta: opts[:window] || state.lookback_seconds,
      counter?: counter?,
      step: bucket_seconds
    ]

    if function_exported?(state.metrics_module, :range_matched, 6) do
      with {:ok, series} <-
             state.metrics_module.range_matched(
               state.store,
               metric_name,
               matchers,
               from_ts,
               to_ts,
               query_opts
             ) do
        # Combined there is one series or none; not combined, the first
        # series the labels match, as metric_range/5 draws.
        {:ok, series |> Enum.map(& &1.points) |> List.first([])}
      end
    else
      legacy_range_matched(
        state,
        metric_name,
        matchers,
        from_ts,
        to_ts,
        bucket_seconds,
        query_opts
      )
    end
  end

  @impl true
  def top_series(state, element, metric_name, %DateTime{} = time, opts) do
    matchers = Element.query_matchers(element)
    lookback = opts[:window] || state.lookback_seconds
    counter? = counter_metric?(state, element, metric_name)
    query_opts = Keyword.merge(opts, lookback_delta: lookback, counter?: counter?)

    if function_exported?(state.metrics_module, :top_series, 5) do
      state.metrics_module.top_series(
        state.store,
        metric_name,
        matchers,
        DateTime.to_unix(time),
        query_opts
      )
    else
      legacy_top_series(state, metric_name, matchers, DateTime.to_unix(time), query_opts)
    end
  end

  # --- TimelessMetrics in the node: read per series, combine here ---

  # Every series the equality labels match, as `[%{labels, data}]`, and then
  # only those the whole matcher list allows: what equality cannot say is
  # said here.
  defp legacy_matched_series(state, metric_name, matchers, from_ts, to_ts, bucket, aggregate) do
    labels = for {key, :eq, [value]} <- matchers, into: %{}, do: {key, value}

    case state.metrics_module.query_aggregate_multi(state.store, metric_name, labels,
           from: from_ts,
           to: to_ts,
           bucket: {bucket, :seconds},
           aggregate: aggregate
         ) do
      {:ok, series} when is_list(series) ->
        {:ok, Enum.filter(series, &Element.matches?(&1.labels, matchers))}

      {:error, _reason} = error ->
        error

      _other ->
        {:ok, []}
    end
  end

  defp legacy_top_series(state, metric_name, matchers, time, opts) do
    lookback = Keyword.fetch!(opts, :lookback_delta)
    # One bucket the width of the lookback: a series' value at `time` is
    # its last sample in it; a counter's is what it rose by a second.
    aggregate = if opts[:counter?], do: :rate, else: :last

    with {:ok, series} <-
           legacy_matched_series(
             state,
             metric_name,
             matchers,
             time - lookback,
             time,
             lookback,
             aggregate
           ) do
      values =
        for %{labels: labels, data: [_ | _] = points} <- series do
          {_ts, value} = List.last(points)
          {labels, value / 1}
        end

      rows =
        case Keyword.get(opts, :group_by, []) do
          [] ->
            Enum.map(values, fn {labels, value} -> %{labels: labels, value: value} end)

          keys ->
            values
            |> Enum.group_by(fn {labels, _} -> Map.take(labels, keys) end, &elem(&1, 1))
            |> Enum.map(fn {group, group_values} ->
              %{labels: group, value: combine(group_values, Keyword.get(opts, :aggregate, :sum))}
            end)
        end

      order = if Keyword.get(opts, :order) == :asc, do: :asc, else: :desc

      {:ok, rows |> Enum.sort_by(& &1.value, order) |> Enum.take(Keyword.get(opts, :limit, 10))}
    end
  end

  defp legacy_range_matched(state, metric_name, matchers, from_ts, to_ts, bucket, opts) do
    aggregate = if opts[:counter?], do: :rate, else: :last

    with {:ok, series} <-
           legacy_matched_series(state, metric_name, matchers, from_ts, to_ts, bucket, aggregate) do
      points =
        case {Keyword.get(opts, :aggregate), series} do
          {nil, [%{data: points} | _]} ->
            points

          {nil, []} ->
            []

          {combine, series} ->
            TimelessMetrics.merge_series_data(Enum.map(series, & &1.data), combine)
        end

      {:ok, Enum.map(points, fn {ts, val} -> {ts * 1000, val} end)}
    end
  end

  defp combine([], _aggregate), do: 0.0
  defp combine(values, :avg), do: Enum.sum(values) / length(values)
  defp combine(values, :max), do: Enum.max(values)
  defp combine(values, :min), do: Enum.min(values)
  defp combine(values, _sum), do: Enum.sum(values)

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

  # The filter is matched as the canvas says: every word of it in the
  # metric's name or in the value of one of the series' labels, so that
  # `proc_cpu postgres` is the postgres series of the process CPU metrics.
  @impl true
  def list_series_for_host(state, host, opts \\ []) do
    Cache.ensure(state.cache_name, {:host_series, host})

    case Cache.get(state.cache_table, {:host_series, host}) do
      {:ok, series} -> TimelessCanvas.DataSource.filter_series(series, opts)
      :miss -> []
    end
  end

  @impl true
  def series_loaded?(state, host) do
    # A cold miss and a host with no series both read as an empty list. The
    # cache is the only thing that knows which one this is.
    Cache.get(state.cache_table, {:host_series, host}) != :miss
  end

  @impl true
  def metric_metadata(state, metric_name) do
    cached_metric_metadata(state, metric_name)
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

  # The canvas says which of an element's fields are labels; a list kept
  # here fell behind it, and a field that configures the element was sent
  # to the store as a label that matched nothing.
  defp build_labels(element), do: Element.query_labels(element)

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
    case cached_metric_metadata(state, metric_name) do
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

    module = logs_mod()

    present_levels =
      [:error, :warning]
      |> Task.async_stream(
        fn level -> {level, module.query([{:level, level} | base_filters])} end,
        max_concurrency: 2,
        ordered: false,
        timeout: Application.get_env(:timeless_stack, :status_query_timeout, 30_000),
        on_timeout: :kill_task
      )
      |> Enum.reduce(MapSet.new(), fn
        {:ok, {level, {:ok, %{entries: [_ | _]}}}}, levels -> MapSet.put(levels, level)
        _result, levels -> levels
      end)

    cond do
      MapSet.member?(present_levels, :error) -> :error
      MapSet.member?(present_levels, :warning) -> :warning
      true -> :ok
    end
  end

  defp latest_metric(state, metric_name, labels) do
    if Code.ensure_loaded?(state.metrics_module) and
         function_exported?(state.metrics_module, :latest_multi, 3) do
      state.metrics_module.latest_multi(state.store, metric_name, labels)
    else
      now = DateTime.utc_now()

      case state.metrics_module.query_multi(state.store, metric_name, labels,
             from: DateTime.to_unix(DateTime.add(now, -300, :second)),
             to: DateTime.to_unix(now)
           ) do
        {:ok, series} ->
          {:ok,
           Enum.flat_map(series, fn
             %{labels: labels, points: [_ | _] = points} ->
               {timestamp, value} = List.last(points)
               [%{labels: labels, timestamp: timestamp, value: value}]

             _row ->
               []
           end)}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp cached_metric_metadata(state, metric_name) do
    key = {:metric_metadata, state.metrics_module, state.store, metric_name}

    case Cache.get_fresh(state.cache_table, key, state.metadata_ttl) do
      {:ok, metadata} ->
        {:ok, metadata}

      :miss ->
        case state.metrics_module.get_metadata(state.store, metric_name) do
          {:ok, metadata} = result ->
            Cache.put(state.cache_table, key, metadata)
            result

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp configured_metrics_module do
    Application.get_env(:timeless_stack, :timeless_metrics_module, TimelessMetrics)
  end
end
