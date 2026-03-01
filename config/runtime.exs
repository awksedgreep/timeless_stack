import Config

# Runtime config only applies in prod (container/release deployments).
# Dev uses compile-time config in dev.exs with local paths.
# Test uses test.exs with temp dirs.
if config_env() == :prod do
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

  # --- UI (Phoenix) ---
  ui_port =
    System.get_env("TIMELESS_UI_PORT", "4000") |> String.to_integer()

  ui_host = System.get_env("PHX_HOST", "localhost")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      "6HpOY7CC/N+rgF+zzOAbGncebnKFnh41LuJzOdNVfa4pK3LApArebfIxP1aB6EBH"

  config :timeless_ui, TimelessUIWeb.Endpoint,
    url: [host: ui_host, port: ui_port],
    http: [ip: {0, 0, 0, 0}, port: ui_port],
    server: true,
    secret_key_base: secret_key_base

  config :timeless_ui, TimelessUI.Repo,
    database: Path.join(data_dir, "timeless_ui.db")

  # Email: use Resend if API key provided, otherwise log to stdout
  resend_key = System.get_env("RESEND_API_KEY")

  if resend_key do
    config :timeless_ui, TimelessUI.Mailer,
      adapter: Swoosh.Adapters.Resend,
      api_key: resend_key

    config :timeless_ui, :mailer_from,
      System.get_env("MAILER_FROM", "noreply@stg.diablodata.com")

    config :swoosh, :api_client, Swoosh.ApiClient.Finch
  else
    config :timeless_ui, TimelessUI.Mailer, adapter: Swoosh.Adapters.Logger
    config :swoosh, :api_client, false
  end
end
