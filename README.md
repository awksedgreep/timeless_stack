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
| 5556 | TimelessUI (Phoenix web dashboard) |
| 8428 | TimelessMetrics (Prometheus-compatible HTTP) |
| 9428 | TimelessLogs (log ingestion HTTP) |
| 10428 | TimelessTraces (OTLP trace ingestion HTTP) |

## Quick Start

### Container (recommended)

```bash
timeless_secret_key_base="$(openssl rand -base64 64)"

podman pull ghcr.io/awksedgreep/timeless-stack:latest

podman run -d \
  --name timeless-stack \
  -e SECRET_KEY_BASE="$timeless_secret_key_base" \
  -p 5556:5556 \
  -p 8428:8428 \
  -p 9428:9428 \
  -p 10428:10428 \
  -v timeless_data:/data \
  --health-cmd "curl -fsS http://localhost:8428/live && curl -fsS http://localhost:9428/live && curl -fsS http://localhost:10428/live && curl -fsS http://localhost:5556 >/dev/null" \
  --health-interval 30s \
  --health-timeout 5s \
  --health-start-period 15s \
  --health-retries 3 \
  ghcr.io/awksedgreep/timeless-stack:latest
```

All data is stored under `/data` (metrics, logs, traces, and the UI database). Mount a volume to persist across restarts.

**Filesystem note:** put the `/data` volume on a filesystem that overwrites
in place (ext4, xfs), or on btrfs with copy-on-write turned off for the
volume's directory. With rootless podman that directory is the volume's
`_data` (`podman volume inspect <name> --format '{{.Mountpoint}}'`):

```bash
podman volume create timeless_stack_data
chattr +C "$(podman volume inspect timeless_stack_data --format '{{.Mountpoint}}')"
```

It has to be set while the directory is empty, before the first start. On
btrfs with copy-on-write, the metrics database fragments into one extent per
page and the writer stalls for seconds under maintenance load; see
[the operations guide](docs/telemetry_data_plane_operations.md#data-volume-filesystem)
for the symptoms and how to convert an existing volume.

**Performance note:** with rootless podman, published ports go through
pasta user-mode forwarding, which costs ~13–18% of peak ingest throughput
at saturation (measured 2026-07-18, timeless_metrics cardinality bank).
For ingest-heavy deployments use `--network=host` (drop the `-p` flags —
the stack binds 5556/8428/9428/10428 directly). Under sustained heavy
ingest also set a generous stop timeout (e.g. `--stop-timeout 120` or
`TimeoutStopSec=` in Quadlets) so the shutdown flush completes. The health
probe is configured by Podman at container creation because the OCI image
format intentionally has no image-level health-check field.

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

From the parent directory containing this repo (the data plane is
downloaded from the named timeless-libsql release, not built from source —
the tag must have published artifacts):

```bash
podman build --ignorefile timeless_stack/.containerignore \
  -t timeless-stack -f timeless_stack/Containerfile \
  --build-arg TARGETARCH=amd64 \
  --build-arg TIMELESS_BUILD_COMMIT=2a6a3c994917e704fff31c78f29b108c08b3da29 \
  --build-arg TIMELESS_BUILD_RELEASE=v0.8.2 .
```

## Architecture

TimelessStack is a thin orchestration layer. The default production data
plane is three supervised, signal-specific Rust API processes backed by the
public `timeless-libsql` extension. Phoenix remains the control plane and the
legacy embedded engines remain available only through the documented offline
rollback window.

The exact supported API/query surface, limits, ownership boundary, and
rollback procedure are frozen in
[`docs/telemetry_data_plane_compatibility.md`](docs/telemetry_data_plane_compatibility.md).

The bundled components are:

- **TimelessMetrics** -- Prometheus-compatible time-series storage and
  extension-owned rollups in libSQL.
- **TimelessLogs** -- Structured rich-log storage in the libSQL block virtual
  table.
- **TimelessTraces** -- OpenTelemetry-compatible rich spans in the libSQL
  trace virtual table.
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

## Metrics Index Cache

The metrics service reads its index (every series and chunk) from the
database, whatever the store's size: it starts in under a second in a few
tens of megabytes, and a read never waits for a write. What it keeps in
memory is a cache of series identities for ingest and of repeated
selections for reads, bounded by

```bash
TIMELESS_METRICS_INDEX_CACHE=64MB
```

Unset, a store keeps the setting it has, which for one this stack created
is `unbounded`: every series' identity is remembered, about 48 bytes each.

Before data plane 0.9.0 the service held the whole index in memory. The
first start of this version on such a store builds two indexes in the
database, once (about four seconds for 700,000 series). Measured on that
store:

| | before | now |
|---|---|---|
| metrics service ready after start | 7.9 s | 0.8 s |
| its memory after start | 1.9 GiB | 77 MiB |
| reads answered beside ingest and maintenance (benchmark) | 3,420, 38 refused, p99 5.1 s | 18,698, none refused, p99 2.5 ms |
| longest maintenance step (same benchmark) | 0.6 s | 0.23 s |
| a count over 98,000 series | 67 ms | 103 ms |

## Health Checks

Each ingestion service exposes a `/health` endpoint:

```bash
curl http://localhost:8428/health   # metrics
curl http://localhost:9428/health   # logs
curl http://localhost:10428/health  # traces
```

## Self Telemetry

Each service reports counters and timings about itself on `/metrics`: write
retries, how long reads waited, how long maintenance steps and flushes took.
Those are only current values unless something keeps reading them, so the
stack reads `/metrics` from the metrics, logs and traces services every 30
seconds and stores the samples in the metrics service, where they can be
queried and graphed like any other series:

```promql
rate(timeless_metrics_write_busy_retries_total[5m])
rate(timeless_metrics_read_wait_nanoseconds_total[5m]) / 1e9
histogram_quantile(0.99, rate(timeless_metrics_maintenance_step_seconds_bucket[5m]))
```

The families are named `timeless_metrics_*`, `timeless_logs_*` and
`timeless_traces_*`, a few hundred series in all. To change the interval or
turn it off:

```bash
TIMELESS_SELF_TELEMETRY_INTERVAL_SECS=30   # the default
TIMELESS_SELF_TELEMETRY_ENABLED=false
```

## License

MIT -- see [LICENSE](LICENSE) for details.
