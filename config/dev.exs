import Config

ui_port = System.get_env("TIMELESS_UI_PORT", "4000") |> String.to_integer()

# Local data directories for dev (config.exs defaults are for containers)
# Ports offset by 10000 to avoid conflict with Victoria* in podman on 8428/9428/10428
config :timeless_metrics,
  data_dir: Path.expand("../data/metrics", __DIR__),
  port: 18428

config :timeless_logs,
  storage: :disk,
  data_dir: Path.expand("../data/logs", __DIR__),
  http: [port: 19428]

config :timeless_traces,
  storage: :disk,
  data_dir: Path.expand("../data/traces", __DIR__),
  http: [port: 20428]

# Enable poller in dev
config :timeless_ui, :poller, enabled: true

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
