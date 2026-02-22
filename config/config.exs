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

# Asset build tools for TimelessUI (path dep at ../timeless_ui)
config :esbuild,
  version: "0.25.4",
  timeless_ui: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../../timeless_ui/assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :tailwind,
  version: "4.1.12",
  timeless_ui: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("../../timeless_ui", __DIR__)
  ]

config :phoenix, :json_library, Jason

# Import environment specific config
import_config "#{config_env()}.exs"
