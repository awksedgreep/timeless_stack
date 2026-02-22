import Config

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

# Disable swoosh api client in dev
config :swoosh, :api_client, false

# Faster polling in dev for more responsive UI
config :timeless_ui, :data_source,
  module: TimelessStack.UIDataSource,
  config: %{metrics_store: :timeless_metrics},
  poll_interval: 2_000
