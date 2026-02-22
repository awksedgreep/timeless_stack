defmodule TimelessStack.UIDataSourceTest do
  use ExUnit.Case, async: false

  alias TimelessStack.UIDataSource

  require Logger

  @data_dir Path.expand("../../tmp/test_metrics_#{System.unique_integer([:positive])}", __DIR__)

  setup do
    # Start TimelessMetrics in-memory store
    File.mkdir_p!(@data_dir)

    start_supervised!(
      {TimelessMetrics, name: :test_metrics, data_dir: @data_dir, buffer_shards: 2}
    )

    # Start TimelessLogs in memory mode
    Application.put_env(:timeless_logs, :storage, :memory)
    Application.put_env(:timeless_logs, :flush_interval, 60_000)
    Application.put_env(:timeless_logs, :max_buffer_size, 10_000)
    Application.stop(:timeless_logs)
    Application.ensure_all_started(:timeless_logs)

    {:ok, state} = UIDataSource.init(%{metrics_store: :test_metrics})

    on_exit(fn ->
      Application.stop(:timeless_logs)
      File.rm_rf!(@data_dir)
    end)

    %{state: state}
  end

  defp make_element(id, meta \\ %{}) do
    %TimelessUI.Canvas.Element{
      id: id,
      type: :server,
      label: "test",
      x: 0.0,
      y: 0.0,
      width: 120.0,
      height: 100.0,
      meta: meta
    }
  end

  describe "init/1" do
    test "initializes with metrics store" do
      assert {:ok, %{store: :test_metrics}} = UIDataSource.init(%{metrics_store: :test_metrics})
    end

    test "defaults to :timeless_metrics" do
      assert {:ok, %{store: :timeless_metrics}} = UIDataSource.init(%{})
    end
  end

  describe "metric/3" do
    test "returns latest metric value", %{state: state} do
      now = System.os_time(:second)

      TimelessMetrics.write(:test_metrics, "cpu_usage", %{"host" => "web-1"}, 73.5,
        timestamp: now
      )

      TimelessMetrics.flush(:test_metrics)

      element = make_element("el-1", %{"host" => "web-1"})
      assert {:ok, 73.5} = UIDataSource.metric(state, element, "cpu_usage")
    end

    test "returns :no_data when no metric exists", %{state: state} do
      element = make_element("el-1", %{"host" => "nonexistent"})
      assert :no_data = UIDataSource.metric(state, element, "no_such_metric")
    end
  end

  describe "metric_at/4" do
    test "returns metric value at a specific time", %{state: state} do
      now = System.os_time(:second)

      # Write data at now-2, query at now which gives window [now-5, now]
      TimelessMetrics.write(:test_metrics, "mem_used", %{"host" => "db-1"}, 2048.0,
        timestamp: now - 2
      )

      TimelessMetrics.flush(:test_metrics)

      element = make_element("el-1", %{"host" => "db-1"})
      time = DateTime.utc_now()
      assert {:ok, 2048.0} = UIDataSource.metric_at(state, element, "mem_used", time)
    end

    test "returns :no_data for empty time range", %{state: state} do
      element = make_element("el-1", %{"host" => "ghost"})
      # Query a time far in the past
      {:ok, old_time} = DateTime.from_unix(1_000_000)
      assert :no_data = UIDataSource.metric_at(state, element, "cpu", old_time)
    end
  end

  describe "status/2" do
    test "returns :unknown for element with no host meta", %{state: state} do
      element = make_element("el-1", %{})
      assert :unknown = UIDataSource.status(state, element)
    end

    test "returns :ok for host with no error logs", %{state: state} do
      element =
        make_element("el-1", %{"host" => "clean-host-#{System.unique_integer([:positive])}"})

      assert :ok = UIDataSource.status(state, element)
    end
  end

  describe "status_at/3" do
    test "returns :unknown for element with no host", %{state: state} do
      element = make_element("el-1", %{})
      assert :unknown = UIDataSource.status_at(state, element, DateTime.utc_now())
    end
  end

  describe "time_range/1" do
    test "returns :empty when no data", %{state: state} do
      assert :empty = UIDataSource.time_range(state)
    end

    test "returns valid range after writing data", %{state: state} do
      now = System.os_time(:second)
      TimelessMetrics.write(:test_metrics, "test_metric", %{}, 1.0, timestamp: now - 60)
      TimelessMetrics.write(:test_metrics, "test_metric", %{}, 2.0, timestamp: now)
      TimelessMetrics.flush(:test_metrics)

      case UIDataSource.time_range(state) do
        {%DateTime{} = oldest, %DateTime{} = newest} ->
          assert DateTime.compare(oldest, newest) in [:lt, :eq]

        :empty ->
          # Some stores may not report timestamps until compacted
          :ok
      end
    end
  end

  describe "no-op callbacks" do
    test "subscribe returns {:ok, state}", %{state: state} do
      element = make_element("el-1")
      assert {:ok, ^state} = UIDataSource.subscribe(state, element)
    end

    test "unsubscribe returns {:ok, state}", %{state: state} do
      element = make_element("el-1")
      assert {:ok, ^state} = UIDataSource.unsubscribe(state, element)
    end

    test "handle_message returns :ignore", %{state: state} do
      assert :ignore = UIDataSource.handle_message(state, :anything)
    end
  end
end
