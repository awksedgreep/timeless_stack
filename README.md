<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/logo-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/logo-light.svg">
    <img src="docs/logo-light.svg" width="300" alt="Timeless">
  </picture>
</p>

<h3 align="center">All-in-One Observability Container</h3>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/hexpm/l/timeless_metrics.svg" alt="License"></a>
</p>

---

> "I found it ironic that the first thing you do to time series data is squash the timestamp. That's how the name Timeless was born." --Mark Cotner

An all-in-one observability container that bundles [TimelessMetrics](https://github.com/awksedgreep/timeless_metrics), [TimelessLogs](https://github.com/awksedgreep/timeless_logs), [TimelessTraces](https://github.com/awksedgreep/timeless_traces), and [TimelessUI](https://github.com/awksedgreep/timeless_ui) into a single deployable image.

## Ports

| Port | Service |
|------|---------|
| 4000 | TimelessUI (Phoenix web dashboard) |
| 8428 | TimelessMetrics (Prometheus-compatible HTTP) |
| 9428 | TimelessLogs (log ingestion HTTP) |
| 10428 | TimelessTraces (OTLP trace ingestion HTTP) |

## Quick Start

### Container (recommended)

```bash
docker pull ghcr.io/awksedgreep/timeless-stack:latest

docker run -d \
  -p 4000:4000 \
  -p 8428:8428 \
  -p 9428:9428 \
  -p 10428:10428 \
  -v timeless_data:/data \
  ghcr.io/awksedgreep/timeless-stack:latest
```

All data is stored under `/data` (metrics, logs, traces, and the UI database). Mount a volume to persist across restarts.

**Performance note:** with rootless podman, published ports go through
pasta user-mode forwarding, which costs ~13–18% of peak ingest throughput
at saturation (measured 2026-07-18, timeless_metrics cardinality bank).
For ingest-heavy deployments use `--network=host` (drop the `-p` flags —
the stack binds 4000/8428/9428/10428 directly). Under sustained heavy
ingest also set a generous stop timeout (e.g. `--stop-timeout 120` or
`TimeoutStopSec=` in quadlets) so the shutdown flush completes.

### From Source

TimelessStack requires three sibling repos checked out side-by-side:

```
parent/
  timeless_stack/
  timeless_metrics/
  timeless_ui/
```

```bash
git clone https://github.com/awksedgreep/timeless_stack.git
git clone https://github.com/awksedgreep/timeless_metrics.git
git clone https://github.com/awksedgreep/timeless_ui.git

cd timeless_stack
mix deps.get
mix assets.setup
mix assets.deploy
mix phx.server
```

## Configuration

All services are configured in `config/config.exs`. Key settings:

```elixir
# Data directories (default to /data/* in container)
config :timeless_metrics, data_dir: "/data/metrics", port: 8428
config :timeless_logs, storage: :disk, data_dir: "/data/logs", http: [port: 9428]
config :timeless_traces, storage: :disk, data_dir: "/data/traces", http: [port: 10428]
```

## Building the Container Locally

From the parent directory containing all three repos:

```bash
docker build -t timeless-stack -f timeless_stack/Dockerfile .
```

## Architecture

TimelessStack is a thin orchestration layer. Each component runs as a supervised OTP application:

- **TimelessMetrics** -- Prometheus-compatible time-series storage using Gorilla compression (delta-of-delta timestamps, XOR'd float values) backed by SQLite.
- **TimelessLogs** -- Structured log storage with SQLite index and compressed blocks (zstd/openzl columnar format).
- **TimelessTraces** -- OpenTelemetry-compatible span storage using the same block architecture as logs.
- **TimelessUI** -- Phoenix LiveView dashboard with real-time canvas visualization, alerting, and metric/log/trace exploration.

## Data Retention

TimelessStack ships with longer retention defaults suited for a dedicated
observability server.

| Engine | Default Retention | Size Limit |
|--------|------------------|------------|
| Metrics (raw) | 90 days | none |
| Metrics (daily rollup) | 365 days | none |
| Logs | 90 days | 2 GB |
| Traces | 90 days | 1 GB |

### Customizing retention

Override in `config/config.exs` or `config/runtime.exs`:

```elixir
config :timeless_logs,
  retention_max_age: 180 * 86_400,         # 180 days
  retention_max_size: 4_294_967_296,       # 4 GB cap (nil = unlimited)
  retention_check_interval: 300_000        # check every 5 minutes

config :timeless_traces,
  retention_max_age: 30 * 86_400,          # 30 days
  retention_max_size: 2_147_483_648        # 2 GB cap
```

For metrics:

```elixir
config :timeless_metrics,
  raw_retention_seconds: 180 * 86_400,     # 180 days raw
  daily_retention_seconds: 730 * 86_400    # 2 years rolled up
```

Setting `retention_max_age` to `nil` disables time-based retention.
Setting `retention_max_size` to `nil` disables size-based retention.

Environment variables can also be used at runtime (see `config/runtime.exs`):

```bash
LOGS_RETENTION_AGE=7776000    # 90 days in seconds
LOGS_RETENTION_SIZE=2147483648
TRACES_RETENTION_AGE=7776000
TRACES_RETENTION_SIZE=1073741824
```

## Health Checks

Each ingestion service exposes a `/health` endpoint:

```bash
curl http://localhost:8428/health   # metrics
curl http://localhost:9428/health   # logs
curl http://localhost:10428/health  # traces
```

## License

MIT -- see [LICENSE](LICENSE) for details.
