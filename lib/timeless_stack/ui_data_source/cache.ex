defmodule TimelessStack.UIDataSource.Cache do
  @moduledoc """
  Supervised cache for UI discovery queries (hosts, label values,
  per-host series lists).

  Owns a public named ETS table that `TimelessStack.UIDataSource` reads
  on the UI request path. All store enumeration (per-metric label-value
  scans, per-metric series listings) happens inside this process, off
  the request path:

    * hosts (label values for `"host"`) and any previously requested
      label keys are refreshed on a TTL tick (`:ttl`, default 60s)
    * per-host series lists are fetched on demand — the first read
      returns a miss and triggers an async fetch; entries are refreshed
      on access once older than `:host_series_ttl` and evicted on the
      next tick once older than `:host_series_evict_after`

  Reads are plain ETS lookups and never block on the store. When a fetch
  fails (for example the metrics store is not running yet), previously
  cached values are kept and the failure is retried after the TTL.

  Configuration (app env, overridable per-instance via `start_link/1`
  options with the same keys):

      config :timeless_stack, TimelessStack.UIDataSource.Cache,
        store: :timeless_metrics,
        ttl: 60_000,
        host_series_ttl: 60_000,
        host_series_evict_after: 600_000

  `:store` defaults to the metrics store configured for the canvas data
  source (`config :timeless_canvas, :data_source`), falling back to
  `:timeless_metrics`.
  """

  use GenServer

  @default_table :timeless_stack_ui_cache
  @default_ttl 60_000
  @default_host_series_ttl 60_000
  @default_evict_after 600_000

  @type cache_key :: {:label_values, String.t()} | {:host_series, String.t()}

  # --- Public API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Name of the ETS table owned by the default cache instance."
  def default_table, do: @default_table

  @doc """
  Read a cached value. A plain ETS lookup — never touches the store.
  Returns `:miss` when the key is absent or the table does not exist.
  """
  @spec get(atom(), cache_key()) :: {:ok, list()} | :miss
  def get(table \\ @default_table, key) do
    case :ets.lookup(table, key) do
      [{^key, values, _fetched_at}] -> {:ok, values}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc """
  Ask the cache to fetch or refresh a key if it is missing or stale.
  Asynchronous; a no-op when the cache is not running.
  """
  @spec ensure(atom(), cache_key()) :: :ok
  def ensure(name \\ __MODULE__, key) do
    GenServer.cast(name, {:ensure, key})
  end

  @doc "Synchronously refresh hosts and all tracked label keys."
  def refresh(name \\ __MODULE__) do
    GenServer.call(name, :refresh, 30_000)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    env = Application.get_env(:timeless_stack, __MODULE__, [])
    opt = fn key, default -> Keyword.get(opts, key, Keyword.get(env, key, default)) end

    table = opt.(:table, @default_table)
    :ets.new(table, [:named_table, :public, :set, read_concurrency: true])

    state = %{
      table: table,
      store: opt.(:store, default_store()),
      metrics_module: opt.(:metrics_module, configured_metrics_module()),
      ttl: opt.(:ttl, @default_ttl),
      host_series_ttl: opt.(:host_series_ttl, @default_host_series_ttl),
      evict_after: opt.(:host_series_evict_after, @default_evict_after),
      label_keys: MapSet.new(["host"])
    }

    {:ok, state, {:continue, :initial_refresh}}
  end

  @impl true
  def handle_continue(:initial_refresh, state) do
    refresh_tracked(state)
    schedule_tick(state.ttl)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    refresh_tracked(state)
    evict_stale_host_series(state)
    schedule_tick(state.ttl)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:refresh, _from, state) do
    refresh_tracked(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:ensure, {:label_values, label_key} = key}, state) do
    state = %{state | label_keys: MapSet.put(state.label_keys, label_key)}

    if stale?(state.table, key, state.ttl) do
      store_result(
        state.table,
        key,
        fetch_label_values(state.metrics_module, state.store, label_key)
      )
    end

    {:noreply, state}
  end

  def handle_cast({:ensure, {:host_series, host} = key}, state) do
    if stale?(state.table, key, state.host_series_ttl) do
      store_result(state.table, key, fetch_host_series(state.metrics_module, state.store, host))
      # The reader that triggered this fetch was answered "empty" and has no
      # other reason to ask again. Without this the value lands in the cache
      # and the page it was fetched for never learns it exists.
      announce_series(host)
    end

    {:noreply, state}
  end

  def handle_cast(_msg, state), do: {:noreply, state}

  # --- Refresh internals ---

  defp refresh_tracked(state) do
    Enum.each(state.label_keys, fn label_key ->
      store_result(
        state.table,
        {:label_values, label_key},
        fetch_label_values(state.metrics_module, state.store, label_key)
      )
    end)
  end

  defp evict_stale_host_series(%{table: table, evict_after: evict_after}) do
    cutoff = now_ms() - evict_after

    :ets.select_delete(table, [
      {{{:host_series, :_}, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}
    ])
  end

  defp schedule_tick(ttl), do: Process.send_after(self(), :tick, ttl)

  # Best-effort: a canvas that is not running is not waiting to hear from us.
  defp announce_series(host) do
    Phoenix.PubSub.broadcast(
      TimelessCanvas.pubsub(),
      TimelessCanvas.DataSource.Manager.series_topic(),
      {:series_loaded, host}
    )
  catch
    _, _ -> :ok
  end

  defp stale?(table, key, ttl) do
    case :ets.lookup(table, key) do
      [{^key, _values, fetched_at}] -> now_ms() - fetched_at > ttl
      [] -> true
    end
  end

  defp store_result(table, key, {:ok, values}) do
    :ets.insert(table, {key, values, now_ms()})
  end

  # Fetch failed (store down or not yet started): keep any previous values
  # and back off until the next TTL window.
  defp store_result(table, key, :error) do
    case :ets.lookup(table, key) do
      [{^key, values, _fetched_at}] -> :ets.insert(table, {key, values, now_ms()})
      [] -> :ets.insert(table, {key, [], now_ms()})
    end
  end

  # Bounded enumeration: one label_values/list_series store call per metric
  # name, results reduced immediately. Runs only inside this process.

  defp fetch_label_values(metrics_module, store, label_key) do
    {:ok, metric_names} = metrics_module.list_metrics(store)

    values =
      metric_names
      |> Enum.flat_map(fn metric_name ->
        case metrics_module.label_values(store, metric_name, label_key) do
          {:ok, values} -> values
          _ -> []
        end
      end)
      |> Enum.uniq()
      |> Enum.sort()

    {:ok, values}
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp fetch_host_series(metrics_module, store, host) do
    {:ok, metric_names} = metrics_module.list_metrics(store)

    series =
      metric_names
      |> Enum.flat_map(fn metric_name ->
        case metrics_module.list_series(store, metric_name) do
          {:ok, series_list} ->
            for %{labels: labels} <- series_list,
                labels["host"] == host,
                do: {metric_name, labels}

          _ ->
            []
        end
      end)
      |> Enum.uniq()

    {:ok, series}
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp default_store do
    :timeless_canvas
    |> Application.get_env(:data_source, [])
    |> Keyword.get(:config, %{})
    |> Map.get(:metrics_store, :timeless_metrics)
  end

  defp configured_metrics_module do
    Application.get_env(:timeless_stack, :timeless_metrics_module, TimelessMetrics)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
