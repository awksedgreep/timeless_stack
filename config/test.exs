import Config

# Override to writable temp paths for tests; use random ports
config :timeless_metrics,
  data_dir: Path.expand("../tmp/test_metrics", __DIR__),
  port: 0

config :timeless_logs,
  storage: :memory,
  http: [port: 0]

config :timeless_traces,
  storage: :memory,
  http: [port: 0]

# Disable OTel exporter in test
config :opentelemetry,
  traces_exporter: :none

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
