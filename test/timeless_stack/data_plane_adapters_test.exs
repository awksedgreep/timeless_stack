defmodule TimelessStack.DataPlaneAdaptersTest do
  use ExUnit.Case, async: false

  alias TimelessStack.{LogsDataPlane, MetricsDataPlane, TracesExporter}

  defmodule FanoutBarrier do
    def wait(signal, operation) do
      case Application.get_env(:timeless_stack, :fanout_test_pid) do
        pid when is_pid(pid) ->
          send(pid, {:fanout_started, self(), signal, operation})

          receive do
            :release_fanout -> :ok
          after
            2_000 -> raise "fan-out test was not released"
          end

        _ ->
          :ok
      end
    end
  end

  defmodule BackupSQLite do
    def signal(destination, signal) do
      {:ok, connection} = Exqlite.Sqlite3.open(destination)

      {:ok, _} =
        TimelessMetrics.DB.execute(
          connection,
          "CREATE TABLE _timeless_schema_migrations(signal TEXT, version INTEGER);",
          []
        )

      {:ok, _} =
        TimelessMetrics.DB.execute(
          connection,
          "INSERT INTO _timeless_schema_migrations VALUES (?1, 1)",
          [signal]
        )

      :ok = Exqlite.Sqlite3.close(connection)
      :ok
    end

    def control(destination) do
      {:ok, connection} = Exqlite.Sqlite3.open(destination)
      {:ok, _} = TimelessMetrics.DB.execute(connection, "CREATE TABLE users(id INTEGER)", [])
      :ok = Exqlite.Sqlite3.close(connection)
      :ok
    end
  end

  defmodule BackupStartup do
    def stats(data_dir, opts) do
      signal = Keyword.fetch!(opts, :signal)

      %{
        ready: true,
        state: :valid_libsql,
        target_path: Path.join(data_dir, "#{signal}.db"),
        source_manifest_digest: Keyword.get(opts, :source_manifest_digest)
      }
    end
  end

  defmodule MetricsClient do
    def export(metric, labels, from, to) do
      send(self(), {:metrics_export, metric, labels, from, to})
      {:ok, [%{metric: metric, labels: labels, points: [{from * 1_000, 1.5}, {to * 1_000, 2.5}]}]}
    end

    def range(metric, labels, from, to, step, aggregate) do
      send(self(), {:metrics_range, metric, labels, from, to, step, aggregate})

      {:ok,
       %{
         "metric" => metric,
         "series" => [%{"labels" => labels, "data" => [[from, 1.5], [to, 2.5]]}]
       }}
    end

    def latest(metric, labels) do
      send(self(), {:metrics_latest, metric, labels})
      {:ok, %{"labels" => labels, "timestamp" => 20, "value" => 2.5}}
    end

    # A nameless selector is how the adapter asks which series report now.
    def prometheus_instant("{" <> _ = query, time, opts) do
      send(self(), {:promql_instant, query, time, opts})

      {:ok,
       %{
         "status" => "success",
         "data" => %{
           "resultType" => "vector",
           "result" => [
             %{
               "metric" => %{"__name__" => "proc_cpu_pct", "host" => "ohm", "pid" => "1"},
               "value" => [1_700_000_000, "1.5"]
             },
             %{
               "metric" => %{"__name__" => "sys_load_1m", "host" => "ohm"},
               "value" => [1_700_000_000, "0.4"]
             }
           ]
         }
       }}
    end

    def prometheus_instant(query, time, opts) do
      send(self(), {:promql_instant, query, time, opts})

      {:ok,
       %{
         "status" => "success",
         "data" => %{
           "resultType" => "vector",
           "result" => [
             %{"metric" => %{"comm" => "beam.smp"}, "value" => [time, "103.2"]},
             %{"metric" => %{"comm" => "cc1plus"}, "value" => [time, "887"]}
           ]
         }
       }}
    end

    def prometheus_range(query, from, to, step, opts) do
      send(self(), {:promql_range, query, from, to, step, opts})

      {:ok,
       %{
         "status" => "success",
         "data" => %{
           "resultType" => "matrix",
           "result" => [%{"metric" => %{}, "values" => [[from, "4"], [to, "6"]]}]
         }
       }}
    end

    def label_values("__name__"), do: {:ok, ["cpu"]}
    def label_values("host"), do: {:ok, ["edge"]}
    def label_values("host", %{"metric" => "cpu"}), do: {:ok, ["edge"]}
    def label_values("type", %{"metric" => "cpu"}), do: {:ok, ["counter64"]}
    def series("cpu"), do: {:ok, [%{"labels" => %{"host" => "edge"}}]}

    def request_json(:get, "/api/v1/series", opts) do
      send(self(), {:metrics_series_matching, opts})
      {:ok, %{"status" => "success", "data" => [%{"__name__" => "cpu", "host" => "edge"}]}}
    end

    def stats do
      TimelessStack.DataPlaneAdaptersTest.FanoutBarrier.wait(:metrics, :info)
      {:ok, %{"oldest_timestamp_seconds" => 10, "newest_timestamp_seconds" => 20}}
    end

    def flush do
      TimelessStack.DataPlaneAdaptersTest.FanoutBarrier.wait(:metrics, :flush)
      {:ok, %{"completed_points" => 2}}
    end

    def backup(destination, _opts) do
      :ok = BackupSQLite.signal(destination, "metrics")
      {:ok, backup_report("metrics", destination)}
    end

    def health, do: {:ok, %{"status" => "ok", "build" => %{"version" => "test"}}}

    defp backup_report(signal, destination) do
      %{
        "signal" => signal,
        "destination" => destination,
        "bytes" => File.stat!(destination).size,
        "schema_version" => 1
      }
    end
  end

  defmodule LogsClient do
    def query(filters) do
      send(self(), {:logs_query, filters})
      {:ok, %{entries: [%{message: "boom"}], total: 1, limit: 1, offset: 0, has_more: false}}
    end

    def field_values(field, filters) do
      send(self(), {:logs_field_values, field, filters})
      {:ok, [%{"value" => "edge"}]}
    end

    def stats do
      TimelessStack.DataPlaneAdaptersTest.FanoutBarrier.wait(:logs, :info)
      {:ok, %{entries: 1}}
    end

    def flush do
      TimelessStack.DataPlaneAdaptersTest.FanoutBarrier.wait(:logs, :flush)
      {:ok, %{completed_entries: 1}}
    end

    def ingest(entries), do: {:ok, length(entries)}

    def backup(destination, _opts) do
      :ok = BackupSQLite.signal(destination, "logs")

      {:ok,
       %{
         "signal" => "logs",
         "destination" => destination,
         "bytes" => File.stat!(destination).size,
         "schema_version" => 1
       }}
    end

    def health, do: {:ok, %{"status" => "ok", "build" => %{"version" => "test"}}}
  end

  defmodule TracesClient do
    def ingest_otlp(body, opts) do
      send(self(), {:otlp, body, opts})
      {:ok, %{}}
    end

    def stats do
      TimelessStack.DataPlaneAdaptersTest.FanoutBarrier.wait(:traces, :info)
      {:ok, %{"total_spans" => 1}}
    end

    def flush do
      TimelessStack.DataPlaneAdaptersTest.FanoutBarrier.wait(:traces, :flush)
      {:ok, %{"completed_spans" => 1}}
    end

    def backup(destination, _opts) do
      :ok = BackupSQLite.signal(destination, "traces")

      {:ok,
       %{
         "signal" => "traces",
         "destination" => destination,
         "bytes" => File.stat!(destination).size,
         "schema_version" => 1
       }}
    end

    def health, do: {:ok, %{"status" => "ready", "build" => %{"version" => "test"}}}
  end

  setup do
    old_metrics = Application.get_env(:timeless_stack, :metrics_data_plane_client)
    old_logs = Application.get_env(:timeless_stack, :logs_data_plane_client)
    old_traces = Application.get_env(:timeless_stack, :traces_data_plane_client)
    Application.put_env(:timeless_stack, :metrics_data_plane_client, MetricsClient)
    Application.put_env(:timeless_stack, :logs_data_plane_client, LogsClient)
    Application.put_env(:timeless_stack, :traces_data_plane_client, TracesClient)

    on_exit(fn ->
      restore(:metrics_data_plane_client, old_metrics)
      restore(:logs_data_plane_client, old_logs)
      restore(:traces_data_plane_client, old_traces)
    end)
  end

  test "metrics adapter preserves complete query and discovery shapes" do
    assert {:ok, [%{points: [{10, 1.5}, {20, 2.5}]}]} =
             MetricsDataPlane.query_multi(:ignored, "cpu", %{"host" => "edge"}, from: 10, to: 20)

    assert_received {:metrics_export, "cpu", %{"host" => "edge"}, 10, 20}

    assert {:ok, [%{data: [{10, 1.5}, {20, 2.5}]}]} =
             MetricsDataPlane.query_aggregate_multi(
               :ignored,
               "cpu",
               %{"host" => "edge"},
               from: 10,
               to: 20,
               bucket: {5, :seconds},
               aggregate: :last
             )

    assert {:ok, ["cpu"]} = MetricsDataPlane.list_metrics(:ignored)
    assert {:ok, ["edge"]} = MetricsDataPlane.label_values(:ignored, "cpu", "host")
    assert {:ok, ["edge"]} = MetricsDataPlane.list_label_values(:ignored, "host")
    assert {:ok, [%{labels: %{"host" => "edge"}}]} = MetricsDataPlane.list_series(:ignored, "cpu")

    assert {:ok, [%{metric: "cpu", labels: %{"host" => "edge"}}]} =
             MetricsDataPlane.list_series_matching(:ignored, %{"host" => "edge"})

    assert_received {:metrics_series_matching, opts}
    assert opts[:params]["match[]"] == ~s({host="edge"})

    # The series reporting now are asked for as an instant query with the
    # window as its lookback, and answered in the shape of the listing.
    assert {:ok,
            [
              %{metric: "proc_cpu_pct", labels: %{"host" => "ohm", "pid" => "1"}},
              %{metric: "sys_load_1m", labels: %{"host" => "ohm"}}
            ]} = MetricsDataPlane.list_series_reporting(:ignored, %{"host" => "ohm"}, 300)

    assert_received {:promql_instant, ~s({host="ohm"}), nil, lookback_delta: 300}

    assert {:ok, [%{timestamp: 20, value: 2.5}]} =
             MetricsDataPlane.latest_multi(:ignored, "cpu", %{"host" => "edge"})

    assert {:ok, %{type: "counter64"}} = MetricsDataPlane.get_metadata(:ignored, "cpu")
  end

  test "metrics adapter ranks and combines through the PromQL routes" do
    matchers = [{"host", :eq, ["ohm"]}, {"kind", :neq, ["slice", "manager"]}]

    assert {:ok, rows} =
             MetricsDataPlane.top_series(:ignored, "unit_memory_bytes", matchers, 1_700_000_000,
               group_by: ["unit"],
               limit: 5,
               order: :desc,
               aggregate: :sum,
               lookback_delta: 30
             )

    assert rows == [
             %{labels: %{"comm" => "cc1plus"}, value: 887.0},
             %{labels: %{"comm" => "beam.smp"}, value: 103.2}
           ]

    assert_received {:promql_instant, query, 1_700_000_000, [lookback_delta: 30]}

    assert query ==
             ~s|topk(5, sum by (unit) (unit_memory_bytes{host="ohm",kind!~"slice\|manager"}))|

    # Ungrouped, ascending, a counter: the bottom of the rates.
    assert {:ok, [%{value: 103.2}, %{value: 887.0}]} =
             MetricsDataPlane.top_series(
               :ignored,
               "cpu_total",
               [{"host", :eq, ["ohm"]}],
               1_700_000_000,
               group_by: [],
               limit: 3,
               order: :asc,
               aggregate: :sum,
               lookback_delta: 45,
               counter?: true
             )

    assert_received {:promql_instant, ~s|bottomk(3, rate(cpu_total{host="ohm"}[45s]))|, _, _}

    assert {:ok, [%{labels: %{}, points: [{1_700_000_000_000, 4.0}, {1_700_003_600_000, 6.0}]}]} =
             MetricsDataPlane.range_matched(
               :ignored,
               "proc_rss_bytes",
               [{"comm", :eq, ["chromium"]}],
               1_700_000_000,
               1_700_003_600,
               aggregate: :sum,
               step: 60,
               lookback_delta: 30
             )

    assert_received {:promql_range, ~s|sum(proc_rss_bytes{comm="chromium"})|, 1_700_000_000,
                     1_700_003_600, 60, [lookback_delta: 30]}

    # No aggregate: the selector itself, and no lookback where none is given.
    assert {:ok, _} = MetricsDataPlane.range_matched(:ignored, "m", [], 0, 60, step: 30)
    assert_received {:promql_range, "m{}", 0, 60, 30, []}
  end

  test "metrics adapter rejects an unsupported bucket without raising" do
    assert {:error, {:unsupported_metrics_bucket, {1, :minutes}}} =
             MetricsDataPlane.query_aggregate_multi(:ignored, "cpu", %{},
               from: 10,
               to: 20,
               bucket: {1, :minutes}
             )
  end

  test "info and flush start all three signal calls concurrently" do
    previous_mode = Application.get_env(:timeless_stack, :data_plane_mode)
    Application.put_env(:timeless_stack, :data_plane_mode, :rust)
    Application.put_env(:timeless_stack, :fanout_test_pid, self())

    on_exit(fn ->
      restore(:data_plane_mode, previous_mode)
      Application.delete_env(:timeless_stack, :fanout_test_pid)
    end)

    info = Task.async(&TimelessStack.info/0)
    release_all_fanout(:info)

    assert %{
             metrics: %{oldest_timestamp: 10, newest_timestamp: 20},
             logs: %{entries: 1},
             traces: %{"total_spans" => 1}
           } = Task.await(info)

    flush = Task.async(&TimelessStack.flush/0)
    release_all_fanout(:flush)
    assert :ok = Task.await(flush)
  end

  test "logs adapter maps only declared indexed metadata and time filters" do
    assert {:ok, %{entries: [_]}} =
             LogsDataPlane.query(
               level: :error,
               metadata: %{"host" => "edge"},
               since: DateTime.from_unix!(10),
               until: 20,
               limit: 1
             )

    assert_received {:logs_query, filters}
    assert filters[:host] == "edge"
    assert filters[:start] == 10
    assert filters[:end] == 20
    refute Keyword.has_key?(filters, :metadata)

    assert {:error, {:unsupported_capability, :logs_metadata_filters, ["request_id"]}} =
             LogsDataPlane.query(metadata: %{"request_id" => "r1"})

    refute_received {:logs_query, _filters}
  end

  test "Rust mode coordinates one checksummed no-clobber backup through the three owners" do
    previous = Application.get_env(:timeless_stack, :data_plane_mode)
    root = Path.join(System.tmp_dir!(), "timeless-backup-#{System.unique_integer([:positive])}")
    target = Path.join(root, "snapshot")
    File.mkdir_p!(root)
    legacy_file = Path.join([root, "source", "metrics", "rust_engine", "block-1"])
    File.mkdir_p!(Path.dirname(legacy_file))
    File.write!(legacy_file, "immutable-legacy-source")
    File.touch!(legacy_file, 1_700_000_000)
    Application.put_env(:timeless_stack, :data_plane_mode, :rust)

    on_exit(fn ->
      restore(:data_plane_mode, previous)
      File.rm_rf(root)
    end)

    control_backup = &BackupSQLite.control/1
    owner = self()

    logs_buffer_flush = fn ->
      send(owner, :logs_buffer_flushed)
      :ok
    end

    data_planes =
      Enum.map([:metrics, :logs, :traces], fn signal ->
        [
          signal: signal,
          extension: "/not-used",
          data_dir: Path.join([root, "source", Atom.to_string(signal)]),
          startup_module: BackupStartup,
          startup_opts:
            [signal: signal] ++
              if(signal == :metrics,
                do: [source_manifest_digest: "retained-metrics-digest"],
                else: []
              )
        ]
      end)

    legacy_manifest = fn
      :metrics, data_dir, _opts ->
        {:ok,
         %{
           digest: "retained-metrics-digest",
           bytes: File.stat!(legacy_file).size,
           json: ~s({"version":1,"signal":"metrics"}),
           files: [
             %{
               path: Path.relative_to(legacy_file, data_dir),
               size: File.stat!(legacy_file).size,
               mtime: File.stat!(legacy_file, time: :posix).mtime,
               sha256:
                 :crypto.hash(:sha256, File.read!(legacy_file)) |> Base.encode16(case: :lower)
             }
           ]
         }}
    end

    assert {:ok, %{path: ^target}} =
             TimelessStack.backup(target,
               data_planes: data_planes,
               control_backup: control_backup,
               logs_buffer_flush: logs_buffer_flush,
               legacy_manifest: legacy_manifest
             )

    assert_received :logs_buffer_flushed

    for file <- ~w(metrics.db logs.db traces.db control.db manifest.json SHA256SUMS) do
      assert File.regular?(Path.join(target, file))
    end

    assert {:ok, %{"format_version" => 1, "signals" => signals}} =
             TimelessStack.Backup.verify(target)

    assert Map.keys(signals) |> Enum.sort() == ~w(logs metrics traces)

    restore = Path.join(root, "restored")
    assert {:ok, %{path: ^restore}} = TimelessStack.Backup.restore(target, restore)

    for signal <- ~w(metrics logs traces) do
      assert File.regular?(Path.join([restore, signal, "#{signal}.db"]))
    end

    assert File.regular?(Path.join(restore, "timeless_ui.db"))

    assert File.read!(Path.join([restore, "metrics", "rust_engine", "block-1"])) ==
             "immutable-legacy-source"

    assert {:error, {:prepare_backup, :destination_exists}} =
             TimelessStack.backup(target,
               data_planes: data_planes,
               control_backup: control_backup,
               legacy_manifest: legacy_manifest
             )
  end

  test "trace exporter uses the SDK OTLP encoder and preserves rich fields" do
    scope = {:instrumentation_scope, "checkout-lib", "2.1.0", "https://schema.test"}
    attributes = :otel_attributes.new(%{"http.method" => "POST", "attempt" => 2}, 128, :infinity)

    events =
      :otel_events.add(
        [
          %{system_time_native: 130, name: "exception", attributes: %{"type" => "Declined"}}
        ],
        :otel_events.new(128, 128, :infinity)
      )

    links = :otel_links.new([], 128, 128, :infinity)

    span =
      {:span, 0x00112233445566778899AABBCCDDEEFF, 0x0011223344556677, [], :undefined, false,
       "POST /checkout", :server, 100, 175, attributes, events, links,
       {:status, :error, "declined"}, 1, false, scope}

    table = :ets.new(:traces_exporter_test, [:duplicate_bag, {:keypos, 17}])
    true = :ets.insert(table, span)

    resource =
      :otel_resource.create(%{"service.name" => "checkout", "service.instance.id" => "edge-1"})

    assert {:ok, state} = TracesExporter.init(client: TracesClient, client_opts: [notify: self()])
    assert :ok = TracesExporter.export(table, resource, state)
    assert_receive {:otlp, body, opts}
    assert opts[:format] == :protobuf
    assert opts[:timeout] == 8_000

    decoded =
      :opentelemetry_exporter_trace_service_pb.decode_msg(
        body,
        :export_trace_service_request
      )

    [resource_spans] = decoded.resource_spans
    assert Enum.any?(resource_spans.resource.attributes, &(&1.key == "service.name"))
    [scope_spans] = resource_spans.scope_spans
    assert scope_spans.scope.name == "checkout-lib"
    assert scope_spans.scope.version == "2.1.0"
    [decoded_span] = scope_spans.spans
    assert decoded_span.name == "POST /checkout"
    assert decoded_span.status.message == "declined"
    assert length(decoded_span.events) == 1
  end

  defp release_all_fanout(operation) do
    started =
      for _ <- 1..3 do
        assert_receive {:fanout_started, pid, signal, ^operation}, 500
        {pid, signal}
      end

    assert MapSet.new(Enum.map(started, &elem(&1, 1))) == MapSet.new([:metrics, :logs, :traces])
    Enum.each(started, fn {pid, _signal} -> send(pid, :release_fanout) end)
  end

  defp restore(key, nil), do: Application.delete_env(:timeless_stack, key)
  defp restore(key, value), do: Application.put_env(:timeless_stack, key, value)
end
