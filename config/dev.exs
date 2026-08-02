import Config

ui_port = System.get_env("TIMELESS_UI_PORT", "4000") |> String.to_integer()

# Local data directories for dev (config.exs defaults are for containers)
# Ports offset by 10000 to avoid conflict with Victoria* in podman on 8428/9428/10428
config :timeless_metrics,
  owner: :external,
  data_dir: Path.expand("../data/metrics", __DIR__),
  port: 18428

config :timeless_logs,
  owner: :external,
  storage: :disk,
  data_dir: Path.expand("../data/logs", __DIR__),
  http: [port: 19428]

config :timeless_traces,
  owner: :external,
  storage: :disk,
  data_dir: Path.expand("../data/traces", __DIR__),
  http: [port: 20428]

# Enable poller in dev
config :timeless_ui, :poller,
  enabled: true,
  metrics_writer: TimelessUI.MetricsDataPlane.Writer

workspace = Path.expand("../..", __DIR__)
extension = Path.join(workspace, "timeless-libsql/target/release/libtimeless_ext.so")
server_dir = Path.join(workspace, "timeless-libsql/servers/target/release")
auth_dir = Path.expand("../data/control/auth", __DIR__)

config :timeless_ui, :telemetry_data_planes, [
  [
    signal: :metrics,
    binary: Path.join(server_dir, "timeless-metrics-api"),
    extension: extension,
    data_dir: Path.expand("../data/metrics", __DIR__),
    listen: "127.0.0.1:18428",
    startup_module: TimelessMetrics.ReleaseStartup,
    auth_policy_path: Path.join(auth_dir, "metrics.json")
  ],
  [
    signal: :logs,
    binary: Path.join(server_dir, "timeless-logs-api"),
    extension: extension,
    data_dir: Path.expand("../data/logs", __DIR__),
    listen: "127.0.0.1:19428",
    startup_module: TimelessLogs.ReleaseStartup,
    startup_opts: [retention_seconds: 90 * 86_400],
    auth_policy_path: Path.join(auth_dir, "logs.json")
  ],
  [
    signal: :traces,
    binary: Path.join(server_dir, "timeless-traces-api"),
    extension: extension,
    data_dir: Path.expand("../data/traces", __DIR__),
    listen: "127.0.0.1:20428",
    startup_module: TimelessTraces.ReleaseStartup,
    startup_opts: [retention_seconds: 90 * 86_400],
    auth_policy_path: Path.join(auth_dir, "traces.json"),
    env: %{"TIMELESS_TRACES_RETENTION_SECS" => Integer.to_string(90 * 86_400)}
  ]
]

config :timeless_ui, :logs_data_plane_buffer, enabled: true

# TimelessUI endpoint dev settings: asset watchers
config :timeless_ui, TimelessUIWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: ui_port],
  debug_errors: true,
  check_origin: false,
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:timeless_ui, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:timeless_ui, ~w(--watch)]}
  ]

# Enable dev routes (mailbox, dashboard) for TimelessUI
config :timeless_ui, dev_routes: true

# Disable swoosh api client in dev
config :swoosh, :api_client, false

# Faster polling in dev for more responsive UI
config :timeless_canvas, :data_source,
  module: TimelessStack.UIDataSource,
  config: %{metrics_store: :timeless_metrics},
  poll_interval: 2_000

# Iconify looks for pre-generated icon SVGs relative to cwd by default;
# point it at the set shipped with timeless_ui (served by its endpoint).
config :iconify_ex,
  generated_icon_static_path: "deps/timeless_ui/priv/static/images/icons"
