import Config

config :timeless_canvas,
  current_user_fn: fn socket_or_conn -> socket_or_conn.assigns.current_scope.user end

if config_env() == :prod do
  data_dir = System.get_env("TIMELESS_DATA_DIR", "/data")

  data_plane_mode =
    case System.get_env("TIMELESS_DATA_PLANE", "rust") do
      "rust" ->
        :rust

      "legacy" ->
        if System.get_env("TIMELESS_LEGACY_ROLLBACK_ACK") == "retain-legacy-until-0.9.0" do
          :legacy
        else
          raise """
          TIMELESS_DATA_PLANE=legacy is an offline, time-limited rollback path.
          Stop the release and set TIMELESS_LEGACY_ROLLBACK_ACK=retain-legacy-until-0.9.0.
          This selector is removed in 0.9.0.
          """
        end

      value ->
        raise "invalid TIMELESS_DATA_PLANE=#{inspect(value)}; expected rust or legacy"
    end

  metrics_port = System.get_env("TIMELESS_METRICS_PORT", "8428") |> String.to_integer()
  logs_port = System.get_env("TIMELESS_LOGS_PORT", "9428") |> String.to_integer()
  traces_port = System.get_env("TIMELESS_TRACES_PORT", "10428") |> String.to_integer()
  # Standalone embedded deployments retain the loopback default.  Container
  # images must opt into an externally reachable bind because the Rust owners
  # run in the same network namespace as Phoenix but are published separately.
  telemetry_bind = System.get_env("TIMELESS_TELEMETRY_BIND", "127.0.0.1")

  # Data-plane authentication. The stack historically hardcoded :required —
  # correct when Phoenix's own clients are the only producers, but a wall in
  # front of external producers (ddnet's log shipper hit 401s on a host
  # whose exposure is already decided at the container boundary). The
  # underlying servers are open by default since timeless-libsql 0.7; this
  # makes the stack's opt-in explicit and overridable per deployment.
  data_plane_auth =
    case System.get_env("TIMELESS_DATA_PLANE_AUTH", "required") do
      "required" -> :required
      "disabled" -> :disabled
      other -> raise "TIMELESS_DATA_PLANE_AUTH must be required or disabled, got #{inspect(other)}"
    end
  telemetry_bind_env =
    if telemetry_bind == "127.0.0.1", do: %{}, else: %{"TIMELESS_ALLOW_NON_LOOPBACK" => "1"}

  metrics_retention_raw =
    System.get_env("TIMELESS_METRICS_RETENTION_RAW", "7") |> String.to_integer()

  logs_retention_age =
    System.get_env("TIMELESS_LOGS_RETENTION_AGE", "604800") |> String.to_integer()

  logs_retention_size =
    System.get_env("TIMELESS_LOGS_RETENTION_SIZE", "536870912") |> String.to_integer()

  traces_retention_age =
    System.get_env("TIMELESS_TRACES_RETENTION_AGE", "604800") |> String.to_integer()

  traces_retention_size =
    System.get_env("TIMELESS_TRACES_RETENTION_SIZE", "536870912") |> String.to_integer()

  metrics_dir = Path.join(data_dir, "metrics")
  logs_dir = Path.join(data_dir, "logs")
  traces_dir = Path.join(data_dir, "traces")

  config :timeless_stack, data_plane_mode: data_plane_mode

  if data_plane_mode == :rust do
    release_root = System.get_env("RELEASE_ROOT", "/opt/timeless")
    bin_dir = System.get_env("TIMELESS_TELEMETRY_BIN_DIR", Path.join(release_root, "bin"))

    extension =
      System.get_env(
        "TIMELESS_LIBSQL_EXTENSION",
        Path.join([release_root, "lib", "libtimeless_ext.so"])
      )

    auth_dir = Path.join([data_dir, "control", "auth"])
    tenant = System.get_env("TIMELESS_TENANT", "default")

    config :timeless_metrics,
      owner: :external,
      engine: :libsql,
      data_dir: metrics_dir,
      raw_retention_seconds: metrics_retention_raw * 86_400

    config :timeless_logs,
      owner: :external,
      storage: :disk,
      data_dir: logs_dir,
      http: false,
      retention_max_age: logs_retention_age,
      retention_max_size: logs_retention_size

    config :timeless_traces,
      owner: :external,
      storage: :disk,
      data_dir: traces_dir,
      http: false,
      retention_max_age: traces_retention_age,
      retention_max_size: traces_retention_size

    config :timeless_ui, :telemetry_data_planes, [
      [
        signal: :metrics,
        binary: Path.join(bin_dir, "timeless-metrics-api"),
        extension: extension,
        data_dir: metrics_dir,
        listen: "#{telemetry_bind}:#{metrics_port}",
        allow_non_loopback: telemetry_bind != "127.0.0.1",
        startup_module: TimelessMetrics.ReleaseStartup,
        auth_mode: data_plane_auth,
        auth_policy_path: Path.join(auth_dir, "metrics.json"),
        tenant: tenant,
        env: telemetry_bind_env
      ],
      [
        signal: :logs,
        binary: Path.join(bin_dir, "timeless-logs-api"),
        extension: extension,
        data_dir: logs_dir,
        listen: "#{telemetry_bind}:#{logs_port}",
        allow_non_loopback: telemetry_bind != "127.0.0.1",
        startup_module: TimelessLogs.ReleaseStartup,
        startup_opts: [retention_seconds: logs_retention_age],
        auth_mode: data_plane_auth,
        auth_policy_path: Path.join(auth_dir, "logs.json"),
        tenant: tenant,
        env: telemetry_bind_env
      ],
      [
        signal: :traces,
        binary: Path.join(bin_dir, "timeless-traces-api"),
        extension: extension,
        data_dir: traces_dir,
        listen: "#{telemetry_bind}:#{traces_port}",
        allow_non_loopback: telemetry_bind != "127.0.0.1",
        startup_module: TimelessTraces.ReleaseStartup,
        startup_opts: [retention_seconds: traces_retention_age],
        auth_mode: data_plane_auth,
        auth_policy_path: Path.join(auth_dir, "traces.json"),
        tenant: tenant,
        env:
          Map.put(
            telemetry_bind_env,
            "TIMELESS_TRACES_RETENTION_SECS",
            Integer.to_string(traces_retention_age)
          )
      ]
    ]

    config :timeless_ui, :logs_data_plane_buffer, enabled: true
    config :timeless_ui, :metrics_scraper_mode, :rust

    config :timeless_ui, :poller, metrics_writer: TimelessUI.MetricsDataPlane.Writer

    config :timeless_stack,
      timeless_metrics_module: TimelessStack.MetricsDataPlane,
      timeless_logs_module: TimelessStack.LogsDataPlane

    config :timeless_stack, TimelessStack.UIDataSource.Cache,
      metrics_module: TimelessStack.MetricsDataPlane

    config :opentelemetry,
      traces_exporter: {TimelessStack.TracesExporter, []}
  else
    storage =
      case System.get_env("TIMELESS_STORAGE", "disk") do
        "memory" -> :memory
        "disk" -> :disk
        value -> raise "invalid TIMELESS_STORAGE=#{inspect(value)}; expected disk or memory"
      end

    bearer_token = System.get_env("TIMELESS_BEARER_TOKEN")
    metrics_config = [owner: :embedded, engine: :rust, data_dir: metrics_dir, port: metrics_port]

    metrics_config =
      if bearer_token,
        do: Keyword.put(metrics_config, :bearer_token, bearer_token),
        else: metrics_config

    config :timeless_metrics, metrics_config

    legacy_http = fn port ->
      if bearer_token, do: [port: port, bearer_token: bearer_token], else: [port: port]
    end

    config :timeless_logs,
      owner: :embedded,
      storage: storage,
      data_dir: logs_dir,
      http: legacy_http.(logs_port),
      retention_max_age: logs_retention_age,
      retention_max_size: logs_retention_size

    config :timeless_traces,
      owner: :embedded,
      storage: storage,
      data_dir: traces_dir,
      http: legacy_http.(traces_port),
      retention_max_age: traces_retention_age,
      retention_max_size: traces_retention_size

    config :timeless_ui, :telemetry_data_planes, []
    config :timeless_ui, :logs_data_plane_buffer, enabled: false
    config :timeless_ui, :metrics_scraper_mode, :embedded
    config :timeless_ui, :poller, metrics_writer: TimelessUI.Poller.MetricsWriter

    config :timeless_stack,
      timeless_metrics_module: TimelessMetrics,
      timeless_logs_module: TimelessLogs

    config :timeless_stack, TimelessStack.UIDataSource.Cache, metrics_module: TimelessMetrics
    config :opentelemetry, traces_exporter: {TimelessTraces.Exporter, []}

    config :timeless_canvas, :data_source,
      module: TimelessStack.UIDataSource,
      config: %{metrics_store: :timeless_metrics, metrics_module: TimelessMetrics},
      poll_interval: 5_000

    config :timeless_canvas, :stream_backends,
      log: TimelessLogs,
      trace: TimelessTraces
  end

  config :opentelemetry, :resource,
    service: [name: "timeless-stack"],
    deployment: [environment: "prod"]

  poller_enabled = System.get_env("TIMELESS_POLLER_ENABLED", "true") == "true"
  config :timeless_ui, :poller, enabled: poller_enabled

  ui_port = System.get_env("TIMELESS_UI_PORT", "4000") |> String.to_integer()
  ui_host = System.get_env("PHX_HOST", "localhost")

  # Which interface the UI listens on. Defaults to all interfaces, preserving
  # existing behaviour. Set to 127.0.0.1 when a reverse proxy terminates TLS in
  # front of it: with host networking there is no port mapping to contain the
  # listener, so the bind address is the only thing keeping the login page off a
  # public IP.
  ui_bind_raw = System.get_env("TIMELESS_UI_BIND", "0.0.0.0")

  ui_bind =
    case :inet.parse_address(String.to_charlist(ui_bind_raw)) do
      {:ok, address} ->
        address

      {:error, _} ->
        raise "TIMELESS_UI_BIND must be an IP address, got #{inspect(ui_bind_raw)}"
    end

  # Fail closed. This previously fell back to a literal committed to a public
  # repository, which anyone could read and use to forge a signed session cookie
  # — walking straight past authentication. A secret that defaults to a working
  # value ships that value to every deployment that forgets to set it.
  # Note the blank check: System.get_env/1 returns "" for a var that is set but
  # empty, and "" is truthy in Elixir, so `get_env(...) || raise` alone would
  # accept `SECRET_KEY_BASE=` and sign cookies with an empty key.
  secret_key_base =
    case System.get_env("SECRET_KEY_BASE") do
      value when is_binary(value) and byte_size(value) > 0 ->
        value

      _ ->
        raise """
        SECRET_KEY_BASE is not set, or is empty.

        Generate one and pass it through the environment:

            openssl rand -base64 64

        It signs session cookies and other tokens, so it must be secret and
        stable across restarts. Changing it invalidates existing sessions.
        """
    end

  config :timeless_ui, TimelessUIWeb.Endpoint,
    url: [host: ui_host, port: ui_port],
    http: [ip: ui_bind, port: ui_port],
    server: true,
    secret_key_base: secret_key_base

  config :timeless_ui, TimelessUI.Repo, database: Path.join(data_dir, "timeless_ui.db")

  resend_key = System.get_env("RESEND_API_KEY")

  if resend_key do
    config :timeless_ui, TimelessUI.Mailer,
      adapter: Swoosh.Adapters.Resend,
      api_key: resend_key

    config :timeless_ui, :mailer_from, System.get_env("MAILER_FROM", "noreply@stg.diablodata.com")
    config :swoosh, :api_client, Swoosh.ApiClient.Finch
  else
    config :timeless_ui, TimelessUI.Mailer, adapter: Swoosh.Adapters.Logger
    config :swoosh, :api_client, false
  end
end
