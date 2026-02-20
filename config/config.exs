import Config

# Disable the default OTLP exporter (timeless_traces receives traces, doesn't export them)
config :opentelemetry,
  traces_exporter: :none

# TimelessMetrics: data_dir gates startup, port for HTTP
config :timeless_metrics,
  data_dir: "/data/metrics",
  port: 8428

# TimelessLogs: storage mode, data dir, HTTP endpoint
config :timeless_logs,
  storage: :disk,
  data_dir: "/data/logs",
  http: [port: 9428]

# TimelessTraces: storage mode, data dir, HTTP endpoint
config :timeless_traces,
  storage: :disk,
  data_dir: "/data/traces",
  http: [port: 10428]

