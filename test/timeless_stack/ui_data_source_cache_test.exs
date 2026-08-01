defmodule TimelessStack.UIDataSource.CacheTest do
  use ExUnit.Case, async: false

  alias TimelessStack.UIDataSource
  alias TimelessStack.UIDataSource.Cache

  @store :cache_test_metrics
  @data_dir Path.expand(
              "../../tmp/test_cache_metrics_#{System.unique_integer([:positive])}",
              __DIR__
            )

  setup do
    File.mkdir_p!(@data_dir)

    start_supervised!({TimelessMetrics, name: @store, data_dir: @data_dir, buffer_shards: 2})

    on_exit(fn -> File.rm_rf!(@data_dir) end)
    :ok
  end

  defp start_cache(opts \\ []) do
    n = System.unique_integer([:positive])
    name = :"ui_cache_#{n}"
    table = :"ui_cache_table_#{n}"

    opts = Keyword.merge([name: name, table: table, store: @store], opts)
    pid = start_supervised!(Supervisor.child_spec({Cache, opts}, id: name))

    # Any GenServer call completes only after the initial refresh
    # (handle_continue) has run.
    :sys.get_state(pid)
    {name, table, pid}
  end

  defp ds_state(name, table) do
    {:ok, state} =
      UIDataSource.init(%{metrics_store: @store, cache_name: name, cache_table: table})

    state
  end

  defp write_metric(metric, labels) do
    TimelessMetrics.write(@store, metric, labels, 1.0, timestamp: System.os_time(:second))
  end

  # Casts sent from this process before a call are processed first, so a
  # sync call after triggering an on-demand fetch makes it deterministic.
  defp sync(pid), do: :sys.get_state(pid)

  describe "refresh populates the cache" do
    test "list_hosts serves the host list from the initial refresh" do
      write_metric("cpu_usage", %{"host" => "web-1"})
      write_metric("cpu_usage", %{"host" => "db-1"})
      TimelessMetrics.flush(@store)

      {name, table, _pid} = start_cache()
      state = ds_state(name, table)

      assert UIDataSource.list_hosts(state) == ["db-1", "web-1"]
    end

    test "manual refresh picks up hosts written after startup" do
      {name, table, _pid} = start_cache()
      state = ds_state(name, table)

      assert UIDataSource.list_hosts(state) == []

      write_metric("cpu_usage", %{"host" => "late-1"})
      TimelessMetrics.flush(@store)
      Cache.refresh(name)

      assert UIDataSource.list_hosts(state) == ["late-1"]
    end

    test "TTL tick refreshes tracked keys" do
      {name, table, _pid} = start_cache(ttl: 50)
      state = ds_state(name, table)

      write_metric("cpu_usage", %{"host" => "ticked-1"})
      TimelessMetrics.flush(@store)

      assert eventually(fn -> UIDataSource.list_hosts(state) == ["ticked-1"] end)
    end
  end

  describe "configuration" do
    test "TTL settings come from app env and are overridable per instance" do
      Application.put_env(:timeless_stack, Cache, ttl: 4_242, host_series_ttl: 999)
      on_exit(fn -> Application.delete_env(:timeless_stack, Cache) end)

      {_name, _table, env_pid} = start_cache()
      assert %{ttl: 4_242, host_series_ttl: 999} = :sys.get_state(env_pid)

      {_name, _table, opt_pid} = start_cache(ttl: 77)
      assert %{ttl: 77, host_series_ttl: 999} = :sys.get_state(opt_pid)
    end
  end

  describe "bounded reads" do
    test "list_hosts applies filter and limit" do
      for host <- ["web-1", "web-2", "db-1"] do
        write_metric("cpu_usage", %{"host" => host})
      end

      TimelessMetrics.flush(@store)
      {name, table, _pid} = start_cache()
      state = ds_state(name, table)

      assert UIDataSource.list_hosts(state, filter: "WEB") == ["web-1", "web-2"]
      assert UIDataSource.list_hosts(state, limit: 1) == ["db-1"]
      assert UIDataSource.list_hosts(state, filter: "web", limit: 1) == ["web-1"]
    end

    test "list_label_values fetches on demand, then serves filtered reads" do
      write_metric("cpu_usage", %{"host" => "web-1", "region" => "us-east"})
      write_metric("cpu_usage", %{"host" => "web-2", "region" => "eu-west"})
      TimelessMetrics.flush(@store)

      {name, table, pid} = start_cache()
      state = ds_state(name, table)

      # First read misses (only "host" is pre-warmed) and triggers a fetch.
      assert UIDataSource.list_label_values(state, "region") == []
      sync(pid)

      assert UIDataSource.list_label_values(state, "region") == ["eu-west", "us-east"]
      assert UIDataSource.list_label_values(state, "region", filter: "east") == ["us-east"]
      assert UIDataSource.list_label_values(state, "region", limit: 1) == ["eu-west"]
    end

    test "list_series_for_host fetches on demand and filters by metric name" do
      write_metric("cpu_usage", %{"host" => "web-1"})
      write_metric("mem_used", %{"host" => "web-1"})
      write_metric("cpu_usage", %{"host" => "other-1"})
      TimelessMetrics.flush(@store)

      {name, table, pid} = start_cache()
      state = ds_state(name, table)

      assert UIDataSource.list_series_for_host(state, "web-1") == []
      sync(pid)

      series = UIDataSource.list_series_for_host(state, "web-1")

      assert Enum.sort(series) == [
               {"cpu_usage", %{"host" => "web-1"}},
               {"mem_used", %{"host" => "web-1"}}
             ]

      assert UIDataSource.list_series_for_host(state, "web-1", filter: "cpu") ==
               [{"cpu_usage", %{"host" => "web-1"}}]

      assert length(UIDataSource.list_series_for_host(state, "web-1", limit: 1)) == 1
    end
  end

  describe "cold cache safety" do
    test "reads return [] without crashing when the cache is not running" do
      {:ok, state} =
        UIDataSource.init(%{
          metrics_store: @store,
          cache_name: :no_such_cache,
          cache_table: :no_such_table
        })

      assert UIDataSource.list_hosts(state) == []
      assert UIDataSource.list_label_values(state, "region") == []
      assert UIDataSource.list_series_for_host(state, "web-1") == []
    end

    test "cache survives a store that is not running" do
      {name, table, pid} = start_cache(store: :nonexistent_store)
      state = ds_state(name, table)

      assert UIDataSource.list_hosts(state) == []
      assert UIDataSource.list_series_for_host(state, "web-1") == []
      sync(pid)
      assert Process.alive?(pid)
    end
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() ->
        true

      attempts <= 0 ->
        false

      true ->
        Process.sleep(20)
        eventually(fun, attempts - 1)
    end
  end
end
