# Rust telemetry boundary correction — C0 baseline

Date: 2026-08-02
Branch: `release/rust-telemetry-data-plane`

## Repository heads

| repository | head before C1 |
|---|---|
| `timeless_stack` | `9cca31b0480d1a74cf2c2af3c385dc139e2a253a` |
| `timeless_ui` | `39b845a5e8839021a9742148dae360c2cc70ceac` |
| `timeless-libsql` | `ff4a6d9f75c5f7c88f6a47ef20e18bcd3477f201` |
| `timeless_canvas` | `72636bfd8120926679ce4c538b213e7db01a950` |

The Stack lockfile resolves `timeless_ui` to `adb84149a87c5ee5f0fd83f3d192fc08fa9fe3c8`
and `timeless_canvas` to `426fff331d96f0134e1ef167714ac755f3452354`, both older
than the selected repository heads.

## Current production paths

### External clients

External metrics, logs, and traces connect directly to the loopback-bound Rust
owners. Phoenix does not proxy those requests and never opens a telemetry
database.

### Phoenix-originated telemetry

- Phoenix Logger events enter `TimelessUI.LogsDataPlane.Buffer`, which batches
  up to 8,192 entries and sends NDJSON to the Rust logs API.
- Phoenix OpenTelemetry spans enter the Erlang batch processor and
  `TimelessStack.TracesExporter`, which sends OTLP protobuf to the Rust traces
  API.
- Prometheus poller jobs run `PrometheusCollector` in Elixir. It performs the
  target HTTP request, regex-parses exposition into Elixir maps, and
  `TimelessUI.MetricsDataPlane.Writer` re-encodes the maps as VictoriaMetrics
  JSON before calling Rust.

The first two are telemetry-origin export bridges. The Prometheus path is
incorrect Rust-mode data-plane ownership because the Rust extension already
has a fused raw exposition parser and `/api/v1/import/prometheus` endpoint.

### Existing Rust Prometheus path

`POST /api/v1/import/prometheus` passes raw bytes through the metrics API to the
public virtual-table insert. `timeless-core::Engine::ingest_prometheus` parses
and resolves samples in one streaming pass. It supports labels, explicit
timestamps, malformed-line accounting, and extension-owned buffering.

## Baseline commands and results

| command | result |
|---|---|
| `cargo test -p timeless-core --test prom_ingest` | 1 passed |
| `cargo test -p timeless-metrics-api --test storage_contract` | 10 ignored because no built extension was supplied; 0 failures |
| `mix test test/timeless_ui/metrics_data_plane/writer_test.exs test/timeless_ui/poller/collector_test.exs` | 2 passed |

The API contract suite requires a built `timeless_ext` shared library and was
therefore not treated as a passing integration baseline. The core parser test
is the authoritative parser baseline; C1 must add raw-scrape and Rust-owned
scraper integration coverage with a real extension.

## C0 exit assessment

C0 is complete: all signal paths, queues, parsers, sockets, owners, and
storage boundaries are identified; the stale UI/Canvas revisions are pinned;
and the current parser and adapter baselines are reproducible. C1 starts by
removing the Elixir Prometheus parse/re-encode path in Rust mode.
