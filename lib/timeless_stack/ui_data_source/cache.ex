defmodule TimelessStack.UIDataSource.Cache do
  @moduledoc """
  Supervised cache for UI discovery queries (hosts, label values,
  per-host series lists).

  Owns a public named ETS table that `TimelessStack.UIDataSource` reads
  on the UI request path. Store enumeration (per-metric label-value scans and
  per-metric series listings) runs in deduplicated tasks, so neither the UI
  request nor this GenServer's mailbox waits for HTTP/store round trips:

    * hosts (label values for `"host"`) and recently requested label keys are
      refreshed on a TTL tick (`:ttl`, default 60s)
    * per-host series lists are fetched on demand — the first read
      returns a miss and triggers an async fetch; entries are refreshed
      on access once older than `:host_series_ttl` and evicted on the
      next tick once older than `:host_series_evict_after`

  Reads are plain ETS lookups and never block on the store. When a fetch
  fails (for example the metrics store is not running yet), previously
  cached values are kept and a cold failure remains a miss. Failures are
  retried after the TTL and never produce a false `series_loaded` broadcast.

  Configuration (app env, overridable per-instance via `start_link/1`
  options with the same keys):

      config :timeless_stack, TimelessStack.UIDataSource.Cache,
        store: :timeless_metrics,
        ttl: 60_000,
        host_series_ttl: 60_000,
        host_series_evict_after: 600_000,
        label_evict_after: 600_000,
        fetch_concurrency: 16,
        fetch_timeout: 30_000

  `:store` defaults to the metrics store configured for the canvas data
  source (`config :timeless_canvas, :data_source`), falling back to
  `:timeless_metrics`.
  """

  use GenServer

  @default_table :timeless_stack_ui_cache
  @default_ttl 60_000
  @default_host_series_ttl 60_000
  @default_evict_after 600_000

  @type cache_key ::
          {:label_values, String.t()}
          | {:host_series, String.t()}
          | {:metric_metadata, module(), term(), String.t()}

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
  @spec get(:ets.table(), cache_key()) :: {:ok, term()} | :miss
  def get(table \\ @default_table, key) do
    case :ets.lookup(table, key) do
      [{^key, values, _fetched_at}] -> {:ok, values}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc "Read a cached value only while it is younger than `ttl`."
  @spec get_fresh(:ets.table(), cache_key(), non_neg_integer()) :: {:ok, term()} | :miss
  def get_fresh(table, key, ttl) do
    case :ets.lookup(table, key) do
      [{^key, value, fetched_at}] when is_integer(fetched_at) ->
        if now_ms() - fetched_at <= ttl, do: {:ok, value}, else: :miss

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc "Store a successful value in the public cache table."
  @spec put(:ets.table(), cache_key(), term()) :: true | false
  def put(table, key, value) do
    :ets.insert(table, {key, value, now_ms()})
  rescue
    ArgumentError -> false
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

    :ets.new(table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    now = now_ms()

    state = %{
      table: table,
      store: opt.(:store, default_store()),
      metrics_module: opt.(:metrics_module, configured_metrics_module()),
      ttl: opt.(:ttl, @default_ttl),
      host_series_ttl: opt.(:host_series_ttl, @default_host_series_ttl),
      evict_after: opt.(:host_series_evict_after, @default_evict_after),
      label_evict_after: opt.(:label_evict_after, @default_evict_after),
      fetch_concurrency: opt.(:fetch_concurrency, 16),
      fetch_timeout: opt.(:fetch_timeout, 30_000),
      task_supervisor: opt.(:task_supervisor, TimelessStack.UIDataSource.Cache.TaskSupervisor),
      label_keys: %{"host" => now},
      inflight: MapSet.new(),
      tasks: %{},
      retry_after: %{},
      refresh_waiters: []
    }

    {:ok, state, {:continue, :initial_refresh}}
  end

  @impl true
  def handle_continue(:initial_refresh, state) do
    state = refresh_tracked(state)
    schedule_tick(state.ttl)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = evict_stale_label_values(state)
    evict_stale_host_series(state)
    evict_stale_metric_metadata(state)
    state = refresh_tracked(state)
    schedule_tick(state.ttl)
    {:noreply, state}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.tasks, ref) do
      {nil, _tasks} ->
        {:noreply, state}

      {key, tasks} ->
        Process.demonitor(ref, [:flush])
        state = %{state | tasks: tasks, inflight: MapSet.delete(state.inflight, key)}
        {:noreply, complete_fetch(state, key, result)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.tasks, ref) do
      {nil, _tasks} ->
        {:noreply, state}

      {key, tasks} ->
        state = %{state | tasks: tasks, inflight: MapSet.delete(state.inflight, key)}
        {:noreply, complete_fetch(state, key, {:error, {:task_exit, reason}})}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:refresh, from, state) do
    keys = tracked_label_keys(state)
    state = Enum.reduce(keys, state, &start_fetch(&2, &1))

    case keys do
      [] ->
        {:reply, :ok, state}

      _ ->
        waiter = %{from: from, pending: MapSet.new(keys)}
        {:noreply, %{state | refresh_waiters: [waiter | state.refresh_waiters]}}
    end
  end

  @impl true
  def handle_cast({:ensure, {:label_values, label_key} = key}, state) do
    state = put_in(state, [:label_keys, label_key], now_ms())

    state = maybe_start_fetch(state, key, state.ttl)

    {:noreply, state}
  end

  def handle_cast({:ensure, {:host_series, _host} = key}, state) do
    {:noreply, maybe_start_fetch(state, key, state.host_series_ttl)}
  end

  def handle_cast(_msg, state), do: {:noreply, state}

  # --- Refresh internals ---

  defp refresh_tracked(state) do
    Enum.reduce(tracked_label_keys(state), state, &start_fetch(&2, &1))
  end

  defp tracked_label_keys(state) do
    state.label_keys
    |> Map.keys()
    |> Enum.map(&{:label_values, &1})
  end

  defp maybe_start_fetch(state, key, ttl) do
    if stale?(state.table, key, ttl) and retry_ready?(state, key) do
      start_fetch(state, key)
    else
      state
    end
  end

  defp start_fetch(state, key) do
    if MapSet.member?(state.inflight, key) do
      state
    else
      metrics_module = state.metrics_module
      store = state.store
      concurrency = state.fetch_concurrency
      timeout = state.fetch_timeout

      task =
        Task.Supervisor.async_nolink(state.task_supervisor, fn ->
          fetch(key, metrics_module, store, concurrency, timeout)
        end)

      %{
        state
        | inflight: MapSet.put(state.inflight, key),
          tasks: Map.put(state.tasks, task.ref, key)
      }
    end
  end

  defp complete_fetch(state, key, {:ok, value}) do
    put(state.table, key, value)

    if match?({:host_series, _host}, key) do
      {:host_series, host} = key

      # The reader that triggered a cold fetch was answered "empty" and has
      # no other reason to ask again. Announce only a completed fetch; a store
      # failure must not make an unloaded host look loaded.
      announce_series(host)
    end

    state
    |> Map.update!(:retry_after, &Map.delete(&1, key))
    |> finish_refresh_waiters(key)
  end

  defp complete_fetch(state, key, _error) do
    retry_at = now_ms() + retry_delay(state, key)

    state
    |> put_in([:retry_after, key], retry_at)
    |> finish_refresh_waiters(key)
  end

  defp finish_refresh_waiters(state, completed_key) do
    {waiting, completed} =
      state.refresh_waiters
      |> Enum.map(fn waiter ->
        %{waiter | pending: MapSet.delete(waiter.pending, completed_key)}
      end)
      |> Enum.split_with(&(MapSet.size(&1.pending) > 0))

    Enum.each(completed, &GenServer.reply(&1.from, :ok))
    %{state | refresh_waiters: waiting}
  end

  defp retry_ready?(state, key) do
    case Map.fetch(state.retry_after, key) do
      :error -> true
      {:ok, retry_at} -> now_ms() >= retry_at
    end
  end

  defp retry_delay(state, {:host_series, _host}), do: state.host_series_ttl
  defp retry_delay(state, _key), do: state.ttl

  defp evict_stale_label_values(state) do
    cutoff = now_ms() - state.label_evict_after

    {expired, kept} =
      Enum.split_with(state.label_keys, fn
        {"host", _last_access} ->
          false

        {label_key, last_access} ->
          last_access < cutoff and
            not MapSet.member?(state.inflight, {:label_values, label_key})
      end)

    Enum.each(expired, fn {label_key, _last_access} ->
      :ets.delete(state.table, {:label_values, label_key})
    end)

    retry_after =
      Enum.reduce(expired, state.retry_after, fn {label_key, _last_access}, retry_after ->
        Map.delete(retry_after, {:label_values, label_key})
      end)

    %{state | label_keys: Map.new(kept), retry_after: retry_after}
  end

  defp evict_stale_host_series(%{table: table, evict_after: evict_after}) do
    cutoff = now_ms() - evict_after

    :ets.select_delete(table, [
      {{{:host_series, :_}, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}
    ])
  end

  defp evict_stale_metric_metadata(%{table: table, evict_after: evict_after}) do
    cutoff = now_ms() - evict_after

    :ets.select_delete(table, [
      {{{:metric_metadata, :_, :_, :_}, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}
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

  defp fetch({:label_values, label_key}, metrics_module, store, concurrency, timeout) do
    fetch_label_values(metrics_module, store, label_key, concurrency, timeout)
  end

  defp fetch({:host_series, host}, metrics_module, store, concurrency, timeout) do
    fetch_host_series(metrics_module, store, host, concurrency, timeout)
  end

  # Bounded enumeration: one label_values/list_series store call per metric
  # name, executed concurrently inside a task and reduced immediately.
  defp fetch_label_values(metrics_module, store, label_key, concurrency, timeout) do
    if Code.ensure_loaded?(metrics_module) and
         function_exported?(metrics_module, :list_label_values, 2) do
      case metrics_module.list_label_values(store, label_key) do
        {:ok, values} when is_list(values) -> {:ok, values |> Enum.uniq() |> Enum.sort()}
        _ -> :error
      end
    else
      with {:ok, metric_names} when is_list(metric_names) <- metrics_module.list_metrics(store),
           {:ok, values} <-
             concurrent_fetch(metric_names, concurrency, timeout, fn metric_name ->
               metrics_module.label_values(store, metric_name, label_key)
             end) do
        {:ok, values |> List.flatten() |> Enum.uniq() |> Enum.sort()}
      else
        _ -> :error
      end
    end
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp fetch_host_series(metrics_module, store, host, concurrency, timeout) do
    if Code.ensure_loaded?(metrics_module) and
         function_exported?(metrics_module, :list_series_matching, 2) do
      case metrics_module.list_series_matching(store, %{"host" => host}) do
        {:ok, series} when is_list(series) ->
          {:ok, Enum.map(series, fn %{metric: metric, labels: labels} -> {metric, labels} end)}

        _ ->
          :error
      end
    else
      with {:ok, metric_names} when is_list(metric_names) <- metrics_module.list_metrics(store),
           {:ok, per_metric} <-
             concurrent_fetch(metric_names, concurrency, timeout, fn metric_name ->
               case metrics_module.list_series(store, metric_name) do
                 {:ok, series_list} when is_list(series_list) ->
                   {:ok,
                    for(
                      %{labels: labels} <- series_list,
                      labels["host"] == host,
                      do: {metric_name, labels}
                    )}

                 _ ->
                   :error
               end
             end) do
        {:ok, per_metric |> List.flatten() |> Enum.uniq()}
      else
        _ -> :error
      end
    end
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp concurrent_fetch(items, concurrency, timeout, fun) do
    items
    |> Task.async_stream(fun,
      max_concurrency: concurrency,
      ordered: false,
      timeout: timeout,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, values}}, {:ok, acc} when is_list(values) ->
        {:cont, {:ok, [values | acc]}}

      _failure, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, values} -> {:ok, values}
      :error -> :error
    end
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
