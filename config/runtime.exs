import Config

# Common root data directory
data_dir = System.get_env("TIMELESS_DATA_DIR", "/data")

# Shared bearer token for all services
bearer_token = System.get_env("TIMELESS_BEARER_TOKEN")

# Storage mode for logs and traces (disk or memory)
storage =
  case System.get_env("TIMELESS_STORAGE", "disk") do
    "memory" -> :memory
    _ -> :disk
  end

# --- Metrics ---
metrics_port =
  System.get_env("TIMELESS_METRICS_PORT", "8428") |> String.to_integer()

metrics_retention_raw =
  System.get_env("TIMELESS_METRICS_RETENTION_RAW", "7") |> String.to_integer()

metrics_config = [
  data_dir: Path.join(data_dir, "metrics"),
  port: metrics_port,
  retention_raw_days: metrics_retention_raw
]

metrics_config =
  if bearer_token,
    do: Keyword.put(metrics_config, :bearer_token, bearer_token),
    else: metrics_config

config :timeless_metrics, metrics_config

# --- Logs ---
logs_port =
  System.get_env("TIMELESS_LOGS_PORT", "9428") |> String.to_integer()

logs_retention_age =
  System.get_env("TIMELESS_LOGS_RETENTION_AGE", "604800") |> String.to_integer()

logs_retention_size =
  System.get_env("TIMELESS_LOGS_RETENTION_SIZE", "536870912") |> String.to_integer()

logs_http =
  if bearer_token,
    do: [port: logs_port, bearer_token: bearer_token],
    else: [port: logs_port]

config :timeless_logs,
  storage: storage,
  data_dir: Path.join(data_dir, "logs"),
  http: logs_http,
  retention_max_age: logs_retention_age,
  retention_max_size: logs_retention_size

# --- Traces ---
traces_port =
  System.get_env("TIMELESS_TRACES_PORT", "10428") |> String.to_integer()

traces_retention_age =
  System.get_env("TIMELESS_TRACES_RETENTION_AGE", "604800") |> String.to_integer()

traces_retention_size =
  System.get_env("TIMELESS_TRACES_RETENTION_SIZE", "536870912") |> String.to_integer()

traces_http =
  if bearer_token,
    do: [port: traces_port, bearer_token: bearer_token],
    else: [port: traces_port]

config :timeless_traces,
  storage: storage,
  data_dir: Path.join(data_dir, "traces"),
  http: traces_http,
  retention_max_age: traces_retention_age,
  retention_max_size: traces_retention_size
