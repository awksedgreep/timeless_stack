import Config

# Disable the default OTLP exporter (timeless_traces receives traces, doesn't export them)
config :opentelemetry,
  traces_exporter: :none

# TimelessMetrics: data_dir gates startup, port for HTTP
config :timeless_metrics,
  data_dir: "/data/metrics",
  port: 8428

# TimelessLogs: server-grade settings for dedicated stack host
config :timeless_logs,
  storage: :disk,
  data_dir: "/data/logs",
  http: [port: 9428],
  retention_max_age: 2_592_000,
  retention_max_size: 2_147_483_648,
  retention_check_interval: 300_000,
  max_term_index_entries: 2_000_000,
  max_buffer_size: 5_000,
  compaction_threshold: 1_000,
  merge_compaction_target_size: 5_000

# TimelessTraces: server-grade settings for dedicated stack host
config :timeless_traces,
  storage: :disk,
  data_dir: "/data/traces",
  http: [port: 10428],
  retention_max_age: 2_592_000,
  retention_max_size: 1_073_741_824,
  retention_check_interval: 300_000,
  max_term_index_entries: 2_000_000,
  max_buffer_size: 5_000,
  compaction_threshold: 1_000,
  merge_compaction_target_size: 5_000

# --- TimelessUI config (dep config files aren't auto-loaded) ---
config :timeless_ui,
  namespace: TimelessUI,
  ecto_repos: [TimelessUI.Repo],
  generators: [timestamp_type: :utc_datetime]

config :timeless_ui, :scopes,
  user: [
    default: true,
    module: TimelessUI.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: TimelessUI.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :timeless_ui, TimelessUIWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: TimelessUIWeb.ErrorHTML, json: TimelessUIWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: TimelessUI.PubSub,
  live_view: [signing_salt: "mRU1QG4S"],
  http: [ip: {127, 0, 0, 1}, port: 4000],
  secret_key_base: "6HpOY7CC/N+rgF+zzOAbGncebnKFnh41LuJzOdNVfa4pK3LApArebfIxP1aB6EBH"

config :timeless_ui, TimelessUI.Repo, database: Path.expand("../data/timeless_ui.db", __DIR__)

config :timeless_ui, TimelessUI.Mailer, adapter: Swoosh.Adapters.Local
config :swoosh, :api_client, false

# Wire TimelessUI to use real stack backends
config :timeless_ui, :data_source,
  module: TimelessStack.UIDataSource,
  config: %{metrics_store: :timeless_metrics},
  poll_interval: 5_000

config :timeless_ui, :stream_backends,
  log: TimelessLogs,
  trace: TimelessTraces

# Route TimelessUI's own spans into TimelessTraces
config :opentelemetry,
  resource: [service: [name: "timeless_ui"]],
  traces_exporter: {TimelessTraces.Exporter, []}

# Asset build tools for TimelessUI
config :esbuild,
  version: "0.25.4",
  timeless_ui: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../deps/timeless_ui/assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :tailwind,
  version: "4.1.12",
  timeless_ui: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("../deps/timeless_ui", __DIR__)
  ]

config :phoenix, :json_library, Jason

# Import environment specific config
import_config "#{config_env()}.exs"
