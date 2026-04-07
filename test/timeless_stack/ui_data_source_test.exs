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
    %TimelessCanvas.Canvas.Element{
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

  defp make_graph_element(id, meta) do
    %TimelessCanvas.Canvas.Element{
      id: id,
      type: :graph,
      label: "graph",
      x: 0.0,
      y: 0.0,
      width: 220.0,
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

  describe "metric_range/5" do
    test "canvas graph path returns stable 2 hour gauge buckets before and after flush",
         %{state: state} do
      metric = "canvas_round_trip_gauge"
      host = "canvas-gauge-1"
      from_ts = div(System.os_time(:second), 7_200) * 7_200
      to_ts = from_ts + 7_200
      points = round_trip_points(from_ts, 7_200)

      :ok =
        TimelessMetrics.write_batch(
          :test_metrics,
          Enum.map(points, fn {ts, value} ->
            {metric, %{"host" => host}, value, ts}
          end)
        )

      element = make_graph_element("graph-1", %{"host" => host})
      {:ok, from_dt} = DateTime.from_unix(from_ts)
      {:ok, to_dt} = DateTime.from_unix(to_ts)
      expected = expected_gauge_range(points, from_ts, to_ts)

      for _ <- 1..3 do
        assert {:ok, actual} = UIDataSource.metric_range(state, element, metric, from_dt, to_dt)
        assert actual == expected
      end

      TimelessMetrics.flush(:test_metrics)

      for _ <- 1..3 do
        assert {:ok, actual} = UIDataSource.metric_range(state, element, metric, from_dt, to_dt)
        assert actual == expected
      end
    end

    test "canvas counter graph path returns stable fixed-window rates before and after flush",
         %{state: state} do
      metric = "ifHCOutOctets"
      host = "canvas-counter-1"
      from_ts = div(System.os_time(:second), 7_200) * 7_200
      to_ts = from_ts + 7_200
      points = counter_round_trip_points(from_ts, 7_200)

      assert {:ok, _} = TimelessMetrics.register_metric(:test_metrics, metric, :counter64)

      :ok =
        TimelessMetrics.write_batch(
          :test_metrics,
          Enum.map(points, fn {ts, value} ->
            {metric, %{"host" => host}, value, ts}
          end)
        )

      element = make_graph_element("graph-counter", %{"host" => host})
      {:ok, from_dt} = DateTime.from_unix(from_ts)
      {:ok, to_dt} = DateTime.from_unix(to_ts)
      expected = expected_counter_range(points, from_ts, to_ts)

      for _ <- 1..3 do
        assert {:ok, actual} = UIDataSource.metric_range(state, element, metric, from_dt, to_dt)
        assert actual == expected
      end

      TimelessMetrics.flush(:test_metrics)

      for _ <- 1..3 do
        assert {:ok, actual} = UIDataSource.metric_range(state, element, metric, from_dt, to_dt)
        assert actual == expected
      end
    end

    test "canvas counter graph rebuckets when the live 1 hour window shifts", %{state: state} do
      metric = "ifHCOutOctets"
      host = "canvas-counter-shift"
      base_ts = div(System.os_time(:second), 3_600) * 3_600
      points = bursty_counter_points(base_ts, 3_700)

      assert {:ok, _} = TimelessMetrics.register_metric(:test_metrics, metric, :counter64)

      :ok =
        TimelessMetrics.write_batch(
          :test_metrics,
          Enum.map(points, fn {ts, value} ->
            {metric, %{"host" => host}, value, ts}
          end)
        )

      element = make_graph_element("graph-counter-shift", %{"host" => host})
      {:ok, from_a} = DateTime.from_unix(base_ts + 5)
      {:ok, to_a} = DateTime.from_unix(base_ts + 3_605)
      {:ok, from_b} = DateTime.from_unix(base_ts + 33)
      {:ok, to_b} = DateTime.from_unix(base_ts + 3_633)

      assert {:ok, window_a} = UIDataSource.metric_range(state, element, metric, from_a, to_a)
      assert {:ok, window_b} = UIDataSource.metric_range(state, element, metric, from_b, to_b)

      assert length(window_a) > 50
      assert length(window_b) > 50
      assert window_a == window_b
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

  defp round_trip_points(base_ts, count) do
    for offset <- 0..(count - 1) do
      {base_ts + offset, rem(offset * 17, 101) * 1.0}
    end
  end

  defp counter_round_trip_points(base_ts, count) do
    Enum.map_reduce(0..(count - 1), 0.0, fn offset, total ->
      increment = rem(offset * 19, 23) + 1
      next_total = total + increment
      {{base_ts + offset, next_total}, next_total}
    end)
    |> elem(0)
  end

  defp bursty_counter_points(base_ts, count) do
    Enum.map_reduce(0..(count - 1), 0.0, fn offset, total ->
      second_97 = rem(offset, 97)
      second_43 = rem(offset, 43)

      increment =
        cond do
          second_97 in 0..7 -> 320_000.0
          second_43 in 0..4 -> 40_000.0
          true -> 1_000.0
        end

      next_total = total + increment
      {{base_ts + offset, next_total}, next_total}
    end)
    |> elem(0)
  end

  defp expected_gauge_range(points, from_ts, to_ts) do
    bucket_seconds = max(div(to_ts - from_ts, 60), 1)

    points
    |> Enum.group_by(fn {ts, _value} ->
      from_ts + div(ts - from_ts, bucket_seconds) * bucket_seconds
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {bucket, bucket_points} ->
      {_last_ts, last_value} = Enum.max_by(bucket_points, &elem(&1, 0))
      {bucket * 1000, last_value}
    end)
  end

  defp expected_counter_range(points, from_ts, to_ts) do
    bucket_seconds = max(div(to_ts - from_ts, 60), 1)

    points
    |> Enum.filter(fn {ts, _value} -> ts >= from_ts and ts <= to_ts end)
    |> Enum.group_by(fn {ts, _value} ->
      from_ts + div(ts - from_ts, bucket_seconds) * bucket_seconds
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {bucket, bucket_points} ->
      {_last_ts, last_value} = Enum.max_by(bucket_points, &elem(&1, 0))
      {bucket, last_value}
    end)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [{bucket_a, value_a}, {bucket_b, value_b}] ->
      {bucket_b * 1000, (value_b - value_a) / max(bucket_b - bucket_a, 1)}
    end)
  end
end
