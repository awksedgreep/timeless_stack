import Config

# Override to writable temp paths for tests; use random ports
config :timeless_metrics,
  owner: :embedded,
  data_dir: Path.expand("../tmp/test_metrics", __DIR__),
  port: 0

config :timeless_logs,
  owner: :embedded,
  storage: :memory,
  data_dir: Path.expand("../tmp/test_logs", __DIR__),
  http: false

config :timeless_traces,
  owner: :embedded,
  storage: :memory,
  data_dir: Path.expand("../tmp/test_traces", __DIR__),
  http: false

# Disable OTel exporter in test
config :opentelemetry,
  traces_exporter: :none

config :timeless_stack,
  data_plane_mode: :legacy,
  timeless_metrics_module: TimelessMetrics,
  timeless_logs_module: TimelessLogs

config :timeless_stack, TimelessStack.UIDataSource.Cache, metrics_module: TimelessMetrics

config :timeless_canvas, :data_source,
  module: TimelessStack.UIDataSource,
  config: %{metrics_store: :timeless_metrics, metrics_module: TimelessMetrics},
  poll_interval: 5_000

config :timeless_canvas, :stream_backends,
  log: TimelessLogs,
  trace: TimelessTraces

config :timeless_ui, :telemetry_data_planes, []
config :timeless_ui, :logs_data_plane_buffer, enabled: false
config :timeless_ui, :metrics_scraper_mode, :embedded
config :timeless_ui, :poller, metrics_writer: TimelessUI.Poller.MetricsWriter

# TimelessUI test config
config :timeless_ui, TimelessUI.Repo,
  database: Path.expand("../tmp/timeless_ui_test.db", __DIR__),
  pool_size: 1,
  pool: Ecto.Adapters.SQL.Sandbox

config :timeless_ui, TimelessUIWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "z9+lj2ZGOlYMbqKvklgVrEnwkPkkE202MP9IW+iY9ZXnhZIcSqkToAxMAv8VWDAO",
  server: false

# Disable Swoosh API client
config :swoosh, :api_client, false

# Reduce bcrypt rounds for faster tests
config :bcrypt_elixir, :log_rounds, 1

config :logger, level: :warning
