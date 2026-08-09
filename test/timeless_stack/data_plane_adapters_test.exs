defmodule TimelessStack.DataPlaneAdaptersTest do
  use ExUnit.Case, async: false

  alias TimelessStack.{LogsDataPlane, MetricsDataPlane, TracesExporter}

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

    def label_values("__name__"), do: {:ok, ["cpu"]}
    def label_values("host", %{"metric" => "cpu"}), do: {:ok, ["edge"]}
    def series("cpu"), do: {:ok, [%{"labels" => %{"host" => "edge"}}]}
    def stats, do: {:ok, %{"oldest_timestamp_seconds" => 10, "newest_timestamp_seconds" => 20}}
    def flush, do: {:ok, %{"completed_points" => 2}}

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

    def stats, do: {:ok, %{entries: 1}}
    def flush, do: {:ok, %{completed_entries: 1}}
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

    def stats, do: {:ok, %{"total_spans" => 1}}
    def flush, do: {:ok, %{"completed_spans" => 1}}

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
    assert {:ok, [%{labels: %{"host" => "edge"}}]} = MetricsDataPlane.list_series(:ignored, "cpu")
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

  defp restore(key, nil), do: Application.delete_env(:timeless_stack, key)
  defp restore(key, value), do: Application.put_env(:timeless_stack, key, value)
end
