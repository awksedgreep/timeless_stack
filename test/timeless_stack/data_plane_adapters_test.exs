defmodule TimelessStack.DataPlaneAdaptersTest do
  use ExUnit.Case, async: false

  alias TimelessStack.{LogsDataPlane, MetricsDataPlane, TracesExporter}

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
  end

  defmodule TracesClient do
    def ingest_otlp(body, opts) do
      send(self(), {:otlp, body, opts})
      {:ok, %{}}
    end
  end

  setup do
    old_metrics = Application.get_env(:timeless_stack, :metrics_data_plane_client)
    old_logs = Application.get_env(:timeless_stack, :logs_data_plane_client)
    Application.put_env(:timeless_stack, :metrics_data_plane_client, MetricsClient)
    Application.put_env(:timeless_stack, :logs_data_plane_client, LogsClient)

    on_exit(fn ->
      restore(:metrics_data_plane_client, old_metrics)
      restore(:logs_data_plane_client, old_logs)
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

  test "Rust mode never invokes direct-owner backup" do
    previous = Application.get_env(:timeless_stack, :data_plane_mode)
    target = Path.join(System.tmp_dir!(), "timeless-backup-refusal-#{System.unique_integer()}")
    Application.put_env(:timeless_stack, :data_plane_mode, :rust)
    on_exit(fn -> restore(:data_plane_mode, previous) end)

    assert {:error, {:unsupported_capability, :coordinated_backup_pending_session_6}} =
             TimelessStack.backup(target)

    refute File.exists?(target)
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
