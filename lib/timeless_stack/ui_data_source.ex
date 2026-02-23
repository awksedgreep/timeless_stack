defmodule TimelessStack.UIDataSource do
  @moduledoc """
  DataSource implementation that wires TimelessUI canvas elements to
  real TimelessMetrics, TimelessLogs, and TimelessTraces data.

  Configured via:

      config :timeless_ui, :data_source,
        module: TimelessStack.UIDataSource,
        config: %{metrics_store: :timeless_metrics},
        poll_interval: 5_000
  """

  @behaviour TimelessUI.DataSource

  @impl true
  def init(config) do
    store = Map.get(config, :metrics_store, :timeless_metrics)
    {:ok, %{store: store}}
  end

  @impl true
  def status(_state, element) do
    case extract_host(element) do
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

    case TimelessMetrics.latest(state.store, metric_name, labels) do
      {:ok, {_ts, value}} -> {:ok, value}
      {:ok, nil} -> :no_data
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

    case TimelessMetrics.query(state.store, metric_name, labels, from: from, to: to) do
      {:ok, [_ | _] = points} ->
        {_ts, value} = List.last(points)
        {:ok, value}

      {:ok, []} ->
        :no_data
    end
  end

  @impl true
  def metric_range(state, element, metric_name, %DateTime{} = from, %DateTime{} = to) do
    labels = build_labels(element)
    from_ts = DateTime.to_unix(from)
    to_ts = DateTime.to_unix(to)

    case TimelessMetrics.query(state.store, metric_name, labels, from: from_ts, to: to_ts) do
      {:ok, points} ->
        # Convert to millisecond timestamps for the graph
        {:ok, Enum.map(points, fn {ts, val} -> {ts * 1000, val} end)}
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
    info = TimelessMetrics.info(state.store)

    case {info[:oldest_timestamp], info[:newest_timestamp]} do
      {nil, _} ->
        :empty

      {_, nil} ->
        :empty

      {oldest, newest} ->
        {:ok, oldest_dt} = DateTime.from_unix(oldest)
        {:ok, newest_dt} = DateTime.from_unix(newest)
        {oldest_dt, newest_dt}
    end
  end

  @impl true
  def list_hosts(state) do
    {:ok, metric_names} = TimelessMetrics.list_metrics(state.store)

    Enum.flat_map(metric_names, fn metric_name ->
      case TimelessMetrics.label_values(state.store, metric_name, "host") do
        {:ok, hosts} -> hosts
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @impl true
  def list_series_for_host(state, host) do
    {:ok, metric_names} = TimelessMetrics.list_metrics(state.store)

    Enum.flat_map(metric_names, fn metric_name ->
      case TimelessMetrics.list_series(state.store, metric_name) do
        {:ok, series_list} ->
          series_list
          |> Enum.filter(fn %{labels: labels} -> labels["host"] == host end)
          |> Enum.map(fn %{labels: labels} -> {metric_name, labels} end)

        _ ->
          []
      end
    end)
    |> Enum.uniq_by(fn {metric_name, _labels} -> metric_name end)
  end

  @impl true
  def metric_metadata(state, metric_name) do
    TimelessMetrics.get_metadata(state.store, metric_name)
  end

  # --- Private ---

  defp extract_host(element) do
    meta = element.meta || %{}
    meta["host"] || meta["service_name"]
  end

  defp build_labels(element) do
    meta = element.meta || %{}

    meta
    |> Map.drop(["metric_name", "y_min", "y_max"])
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
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
    case TimelessLogs.query([{:level, :error} | base_filters]) do
      {:ok, %{entries: [_ | _]}} ->
        :error

      _ ->
        # Check for warnings
        case TimelessLogs.query([{:level, :warning} | base_filters]) do
          {:ok, %{entries: [_ | _]}} -> :warning
          _ -> :ok
        end
    end
  end
end
