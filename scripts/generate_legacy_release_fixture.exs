defmodule TimelessStack.GenerateLegacyReleaseFixture do
  @moduledoc false

  def run([root]) do
    root = Path.expand(root)
    refuse_occupied_root!(root)
    File.mkdir_p!(root)

    generate_metrics(Path.join(root, "metrics"))
    generate_logs(Path.join(root, "logs"))
    generate_traces(Path.join(root, "traces"))

    IO.puts(root)
  end

  def run(_args) do
    raise "usage: mix run --no-start scripts/generate_legacy_release_fixture.exs DATA_DIR"
  end

  defp generate_metrics(data_dir) do
    configure(:timeless_metrics, owner: :embedded, engine: :rust, data_dir: data_dir, port: 0)
    {:ok, _apps} = Application.ensure_all_started(:timeless_metrics)
    now = System.system_time(:second)

    :ok =
      TimelessMetrics.write(:timeless_metrics, "release.legacy.metric", %{"host" => "edge"}, 1.5,
        timestamp: now - 1
      )

    :ok =
      TimelessMetrics.write(:timeless_metrics, "release.legacy.metric", %{"host" => "edge"}, -0.0,
        timestamp: now
      )

    :ok = TimelessMetrics.flush(:timeless_metrics)
    :ok = Application.stop(:timeless_metrics)
  end

  defp generate_logs(data_dir) do
    configure(:timeless_logs,
      owner: :embedded,
      storage: :disk,
      data_dir: data_dir,
      http: false,
      retention_max_age: 0,
      retention_max_size: 0
    )

    {:ok, _apps} = Application.ensure_all_started(:timeless_logs)
    now = System.os_time(:microsecond)

    :ok =
      TimelessLogs.ingest([
        %{
          timestamp: now - 1,
          level: :notice,
          message: "release legacy log",
          metadata: %{
            "service" => "legacy-api",
            "host" => "edge",
            "nested" => %{"attempt" => 2},
            "retryable" => true
          }
        },
        %{
          timestamp: now,
          level: :critical,
          message: "release legacy critical",
          metadata: %{"service" => "legacy-api", "status" => 503}
        }
      ])

    :ok = TimelessLogs.flush()
    :ok = Application.stop(:timeless_logs)
  end

  defp generate_traces(data_dir) do
    configure(:timeless_traces,
      owner: :embedded,
      storage: :disk,
      data_dir: data_dir,
      http: false,
      retention_max_age: 0,
      retention_max_size: 0
    )

    {:ok, _apps} = Application.ensure_all_started(:timeless_traces)
    now = System.os_time(:nanosecond)
    trace_id = "00112233445566778899aabbccddeeff"

    spans = [
      %TimelessTraces.Span{
        trace_id: trace_id,
        span_id: "0102030405060708",
        parent_span_id: nil,
        name: "release legacy root",
        kind: :server,
        start_time: now,
        end_time: now + 50_000_000,
        duration_ns: 50_000_000,
        status: :error,
        status_message: "fixture failure",
        attributes: %{"retryable" => true, "count" => 7},
        events: [%{"name" => "exception", "timestamp" => now + 10}],
        resource: %{"service.name" => "legacy-trace-api", "replica" => 2},
        instrumentation_scope: %{"name" => "release-fixture", "version" => "1.0"}
      },
      %TimelessTraces.Span{
        trace_id: trace_id,
        span_id: "1112131415161718",
        parent_span_id: "0102030405060708",
        name: "release legacy child",
        kind: :client,
        start_time: now + 1_000,
        end_time: now + 20_001_000,
        duration_ns: 20_000_000,
        status: :ok,
        status_message: nil,
        attributes: %{"db.system" => "sqlite"},
        events: [],
        resource: %{"service.name" => "legacy-trace-api"},
        instrumentation_scope: %{"name" => "release-fixture", "version" => "1.0"}
      }
    ]

    :ok = TimelessTraces.Buffer.ingest(spans)
    :ok = TimelessTraces.flush()
    :ok = Application.stop(:timeless_traces)
  end

  defp configure(app, values) do
    Enum.each(values, fn {key, value} ->
      Application.put_env(app, key, value, persistent: true)
    end)
  end

  defp refuse_occupied_root!(root) do
    if File.exists?(root) and File.ls!(root) != [] do
      raise "refusing to overwrite non-empty legacy fixture root #{root}"
    end
  end
end

TimelessStack.GenerateLegacyReleaseFixture.run(System.argv())
