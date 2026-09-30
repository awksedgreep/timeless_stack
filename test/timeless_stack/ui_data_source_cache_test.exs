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
    {wait_for_refresh?, opts} = Keyword.pop(opts, :wait_for_refresh, true)
    n = System.unique_integer([:positive])
    name = :"ui_cache_#{n}"
    table = :"ui_cache_table_#{n}"

    opts = Keyword.merge([name: name, table: table, store: @store], opts)
    pid = start_supervised!(Supervisor.child_spec({Cache, opts}, id: name))

    if wait_for_refresh?, do: Cache.refresh(name)
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

  defp sync(pid) do
    assert eventually(fn -> MapSet.size(:sys.get_state(pid).inflight) == 0 end)
  end

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

    test "the series filter matches the values of labels, as the canvas says" do
      write_metric("proc_cpu_pct", %{"host" => "web-1", "comm" => "postgres", "pid" => "40"})
      write_metric("proc_cpu_pct", %{"host" => "web-1", "comm" => "beam.smp", "pid" => "41"})
      write_metric("proc_rss_bytes", %{"host" => "web-1", "comm" => "postgres", "pid" => "40"})
      TimelessMetrics.flush(@store)

      {name, table, pid} = start_cache()
      state = ds_state(name, table)
      UIDataSource.list_series_for_host(state, "web-1")
      sync(pid)

      postgres = UIDataSource.list_series_for_host(state, "web-1", filter: "postgres")
      assert Enum.map(postgres, &elem(&1, 0)) |> Enum.sort() == ["proc_cpu_pct", "proc_rss_bytes"]

      assert [{"proc_cpu_pct", %{"comm" => "postgres"}}] =
               UIDataSource.list_series_for_host(state, "web-1", filter: "proc_cpu Postgres")

      assert UIDataSource.list_series_for_host(state, "web-1", filter: "nginx") == []
    end
  end

  describe "which series a host has" do
    defmodule ReportingMetrics do
      # Answers which series report within a window as the Rust plane's
      # adapter does, refusing a window wider than the test allows, as the
      # plane refuses to count too many points.
      def list_series_reporting(_store, %{"host" => host}, window) do
        send(:reporting_test, {:reporting, host, window})

        cond do
          window > max_window() -> {:error, {:unexpected_response, 422, "work point limit"}}
          true -> {:ok, reporting(host)}
        end
      end

      def list_series_matching(_store, %{"host" => host}) do
        send(:reporting_test, {:matching, host})

        {:ok,
         reporting(host) ++
           [%{metric: "proc_cpu_pct", labels: %{"host" => host, "pid" => "ended"}}]}
      end

      def list_label_values(_store, "host"), do: {:ok, ["ohm"]}
      def list_label_values(_store, _key), do: {:ok, []}

      defp max_window, do: Application.get_env(:timeless_stack, :reporting_test_max_window, 120)

      defp reporting(host) do
        for pid <- 1..Application.get_env(:timeless_stack, :reporting_test_count, 3) do
          %{metric: "proc_cpu_pct", labels: %{"host" => host, "pid" => Integer.to_string(pid)}}
        end
      end
    end

    setup do
      Process.register(self(), :reporting_test)

      on_exit(fn ->
        Application.delete_env(:timeless_stack, :reporting_test_max_window)
        Application.delete_env(:timeless_stack, :reporting_test_count)
      end)

      :ok
    end

    defp loaded_series(opts) do
      {name, table, pid} =
        start_cache(
          Keyword.merge([metrics_module: ReportingMetrics, wait_for_refresh: false], opts)
        )

      state = ds_state(name, table)
      UIDataSource.list_series_for_host(state, "ohm")
      sync(pid)
      UIDataSource.list_series_for_host(state, "ohm")
    end

    test "are the series that reported within the window, not every series there has been" do
      series = loaded_series([])

      assert Enum.map(series, fn {_metric, labels} -> labels["pid"] end) |> Enum.sort() ==
               ["1", "2", "3"]

      assert_received {:reporting, "ohm", 120}
      refute_received {:matching, "ohm"}
    end

    test "narrow to the lookback where the plane will not count the window, then take all" do
      Application.put_env(:timeless_stack, :reporting_test_max_window, 30)
      series = loaded_series(series_window_seconds: 300, lookback_seconds: 30)
      assert length(series) == 3
      assert_received {:reporting, "ohm", 300}
      assert_received {:reporting, "ohm", 30}
      refute_received {:matching, "ohm"}

      Application.put_env(:timeless_stack, :reporting_test_max_window, 1)
      series = loaded_series(series_window_seconds: 300, lookback_seconds: 30)
      assert "ended" in Enum.map(series, fn {_metric, labels} -> labels["pid"] end)
      assert_received {:matching, "ohm"}
    end

    test "are at most the limit, and the cut is logged" do
      Application.put_env(:timeless_stack, :reporting_test_count, 12)

      {series, log} =
        ExUnit.CaptureLog.with_log(fn -> loaded_series(host_series_limit: 5) end)

      assert length(series) == 5
      assert log =~ "keeps 5 of 12 series for host \"ohm\""
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

  defmodule BlockingMetrics do
    def list_metrics(_store), do: {:ok, ["a", "b", "c"]}

    def label_values(_store, metric, _label_key) do
      test_pid = Application.fetch_env!(:timeless_stack, :blocking_metrics_test_pid)
      send(test_pid, {:fetch_started, self(), metric})

      receive do
        :release -> {:ok, [metric]}
      after
        2_000 -> :error
      end
    end
  end

  describe "asynchronous bounded refresh" do
    test "fan-out is concurrent and does not block the cache mailbox" do
      Application.put_env(:timeless_stack, :blocking_metrics_test_pid, self())
      on_exit(fn -> Application.delete_env(:timeless_stack, :blocking_metrics_test_pid) end)

      {name, table, pid} =
        start_cache(
          metrics_module: BlockingMetrics,
          fetch_concurrency: 3,
          wait_for_refresh: false
        )

      fetches =
        for _ <- 1..3 do
          assert_receive {:fetch_started, fetch_pid, metric}, 500
          {fetch_pid, metric}
        end

      assert MapSet.new(Enum.map(fetches, &elem(&1, 1))) == MapSet.new(["a", "b", "c"])

      # The worker calls are still blocked, but the GenServer remains responsive.
      assert %{inflight: inflight} = :sys.get_state(pid, 100)
      assert MapSet.member?(inflight, {:label_values, "host"})

      Enum.each(fetches, fn {fetch_pid, _metric} -> send(fetch_pid, :release) end)
      assert :ok = Cache.refresh(name)
      assert Cache.get(table, {:label_values, "host"}) == {:ok, ["a", "b", "c"]}
    end

    test "a failed cold series fetch stays unloaded and does not announce success" do
      {name, table, pid} =
        start_cache(metrics_module: __MODULE__.FailingMetrics, wait_for_refresh: false)

      Phoenix.PubSub.subscribe(
        TimelessCanvas.pubsub(),
        TimelessCanvas.DataSource.Manager.series_topic()
      )

      Cache.ensure(name, {:host_series, "missing"})

      assert eventually(fn ->
               not MapSet.member?(:sys.get_state(pid).inflight, {:host_series, "missing"})
             end)

      assert Cache.get(table, {:host_series, "missing"}) == :miss
      refute_receive {:series_loaded, "missing"}, 100
    end
  end

  describe "tracked-key eviction" do
    test "inactive custom label keys stop refreshing and leave the cache" do
      write_metric("cpu_usage", %{"host" => "web-1", "region" => "us-east"})
      TimelessMetrics.flush(@store)

      {name, table, pid} = start_cache(ttl: 60_000, label_evict_after: 5)
      state = ds_state(name, table)

      assert UIDataSource.list_label_values(state, "region") == []
      sync(pid)
      assert Cache.get(table, {:label_values, "region"}) == {:ok, ["us-east"]}

      Process.sleep(10)
      send(pid, :tick)
      sync(pid)

      refute Map.has_key?(:sys.get_state(pid).label_keys, "region")
      assert Cache.get(table, {:label_values, "region"}) == :miss
    end
  end

  defmodule FailingMetrics do
    def list_metrics(_store), do: {:error, :unavailable}
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
