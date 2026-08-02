# Rust/libSQL telemetry data plane compatibility

Status: release-promotion branch, Session 5
Default owner: signal-specific Rust API processes backed by `timeless-libsql`

This document freezes the application boundary for the first release that
uses the Rust/libSQL data plane by default. It is intentionally narrower than
the complete legacy HTTP surface. A route or query shape not listed here is
unsupported: it must return an explicit error and is never forwarded to
Rocket, an embedded Elixir owner, or another database connection.

## Runtime ownership

- Phoenix remains the control plane for users, sessions, token issuance,
  authorization policy, tenancy, configuration, cluster administration, and
  UI state.
- `timeless-metrics-api`, `timeless-logs-api`, and `timeless-traces-api` each
  own exactly one signal database. They listen on loopback by default and
  require Phoenix-issued credentials and policy files.
- The binaries use the public `timeless-libsql` virtual tables and commands.
  They do not implement a second block store. Extension batching,
  compression, indexing, metrics rollups, retention, and maintenance remain
  authoritative.
- The `timeless_metrics`, `timeless_logs`, and `timeless_traces` OTP
  applications stay loaded for migration and rollback code, but their
  storage trees and Rocket listeners do not start in Rust mode.
- Startup state detection and migration finish before a Rust child is marked
  ready. A failure is closed; there is no per-request fallback.

The production default is:

```text
TIMELESS_DATA_PLANE=rust
```

## Metrics

Supported ingestion:

- `POST /api/v1/import/prometheus`: Prometheus text exposition.
- `POST /api/v1/import`: VictoriaMetrics JSON-line import.
- Phoenix poller output containing numeric samples. Text-valued poller
  samples fail explicitly.

Supported reads:

- native exact latest through `GET|POST /api/v1/query` with `metric` and
  exact label equality;
- native exact range through `GET|POST /api/v1/query_range`, inclusive
  bounds, positive step, and `avg|min|max|sum|count|last|first|rate`;
- VictoriaMetrics JSON-line raw export through `GET /api/v1/export`;
- label names, label values, and series discovery through `/api/v1/*`;
- Prometheus aliases for query, query-range, labels, label values, and series;
- PromQL instant vector selectors and
  `avg_over_time(vector-selector[window])` range/instant evaluation; and
- Canvas graph history and TimelessMetricsDashboard historical reads through
  the same Rust routes.

Unsupported metrics behavior includes every other PromQL function,
aggregation, binary/unary operator, modifier, subquery, or offset; regex or
negative matchers outside the implemented selector rules; text-valued
metrics; the embedded metadata registry; and embedded Prometheus scrape-target
CRUD. These return a stable explicit error. They never cross to the legacy
engine.

The extension keeps the 4,096-point per-series raw flush threshold, the
configured rollup ladder, the ten-second low-volume flush, five-minute
compact/rollup, and retention behavior.

## Logs

Supported ingestion:

- `POST /insert/jsonline` with newline-delimited JSON;
- `_time`, `_msg`, and all eight exact severities: `debug`, `info`, `notice`,
  `warning`, `error`, `critical`, `alert`, and `emergency`; and
- complete typed/nested metadata. It is not flattened on the Rust/libSQL
  path.

Supported reads:

- `GET /select/logsql/query` filters: `level`, `message`, `service`, `host`,
  `path`, `status`, `start`, `end`, positive `limit`, non-negative `offset`,
  and `asc|desc` order;
- `POST /select/logsql/query` with the deliberately narrow LogsQL grammar:
  `*`, `_time:<positive s|m|h|d>`, one exact `level:`, one `service:`, one
  double-quoted message substring, `| limit N`, and `| stats count(*)` or
  `count()`;
- field discovery for `service`, `host`, `path`, and `status`; and
- TimelessLogsDashboard historical query, stats, pagination, and field
  discovery through those routes.

Unknown GET parameters, unknown fields, malformed or broader LogsQL, regex,
boolean expressions, arbitrary sort/group pipelines, and dashboard live-tail
subscriptions are unsupported and fail explicitly.

The extension's 8,192-entry batching, level partitioning, term indexes,
compression, bounded optimize policy, and retention remain authoritative.
The UI-side producer buffer is also bounded to at most 8,192 entries and
drains before the Rust owner during normal release shutdown.

## Traces

Supported ingestion:

- `POST /insert/opentelemetry/v1/traces` with OTLP JSON, OTLP protobuf, or
  gzip-compressed OTLP protobuf; and
- complete rich-span fidelity: IDs and parent relationships, nanosecond
  timestamps, kind/status/status description, typed attributes, events,
  resource attributes, and instrumentation scope.

Supported reads:

- Jaeger service and operation discovery;
- Jaeger trace-by-ID;
- Jaeger search with `service`, `operation`, `start`, `end`, positive
  `limit`, `minDuration`, and `maxDuration`;
- native dashboard span search with `name`, `service`, `kind`, `status`,
  `since`, `until`, positive `limit`, non-negative `offset`, and `asc|desc`;
- native complete rich trace-by-ID; and
- TimelessTracesDashboard historical reads through the native routes.

Jaeger search retains the established compatibility rule that `limit` counts
spans before grouping, so one returned trace can be incomplete. Attribute
predicates, arbitrary full-text expressions, unknown query parameters, and
dashboard live-tail subscriptions are unsupported and fail explicitly.

The extension's 8,192-span batching, rich-span codec, trace/service/operation
indexes, bounded optimize policy, and retention remain authoritative.

## Control, health, and limits

Each signal exposes `/live`, `/ready`, `/health`, signal stats, and an ordered
flush barrier. Readiness includes startup/migration state, capability and
minimum-version negotiation, build identity, and storage health. Phoenix
exposes the combined state under its authenticated telemetry administration
API.

Authorization is required by default. The shipped policy defaults are:

| limit | default maximum |
|---|---:|
| request body | 10 MiB |
| decompressed body | 10 MiB |
| response body | 16 MiB |
| query rows | 100,000 |
| request duration | 30 seconds |
| concurrent requests per token | 64 |
| admission queue wait | 1 second |

The signal writer queue defaults to 256 requests and the measured SQLite
reader default is two connections per signal. Claims may lower but never
raise the configured maximums. Queue, request, decompression, query-row,
response, deadline, concurrency, scope, signal, tenant, and retention limits
fail with stable errors; partial responses are not exposed.

## Backup status

Rust-mode backup is coordinated through `TimelessStack.backup/2`. It first
drains the Phoenix logs transport buffer, then asks each owning Rust process
to flush, optimize, checkpoint, and copy its database through the SQLite
online-backup API. Phoenix never opens a telemetry database. The snapshot also
contains the Phoenix control database, authorization policy files, exact
build/health reports, checksums, the original storage layout, and every
immutable legacy source retained for rollback.

A backup is rejected while any signal is migrating or not ready. Publication
is atomic and never overwrites an existing path. Restore is offline-only into
a new or empty data directory and verifies the complete checksum inventory,
SQLite integrity, and signal schema ledger before publication. See
[`telemetry_data_plane_operations.md`](telemetry_data_plane_operations.md).

## Time-limited offline rollback

The rollback selector exists through the first release window and is promised
for removal in 0.9.0. It is offline only:

1. Stop the complete release and verify all three Rust children have exited.
2. Keep the libSQL targets and the retained legacy stores unchanged.
3. Set:

   ```text
   TIMELESS_DATA_PLANE=legacy
   TIMELESS_LEGACY_ROLLBACK_ACK=retain-legacy-until-0.9.0
   ```

4. Start the previous compatible release and run metrics, logs, and traces
   semantic smoke queries.

The acknowledgement is required so rollback cannot be selected accidentally.
Writes accepted by the new libSQL owner after cutover are not present in the
immutable legacy rollback source; running legacy mode therefore creates a
divergent timeline. Do not alternate owners. For an exact rollback including
post-cutover writes, restore a verified release backup to a separate data
directory and use a compatible Rust/libSQL release. Legacy data is never
deleted automatically.
