# Rust telemetry data-plane boundary corrections

Date: 2026-08-02
Branch: `release/rust-telemetry-data-plane`
Status: correction sessions C0-C4 implemented; final clean release gate remains

## Scope decision

The production boundary is:

- Rust owns telemetry-facing HTTP APIs, Prometheus scraping and parsing,
  admission queues, authoritative batching, compression, storage,
  maintenance, and queries.
- Phoenix owns users, sessions, authorization policy, scrape-target and
  cluster configuration, administration, and UI/Canvas state.
- Telemetry originating inside the BEAM may use a small bounded export
  bridge, but that bridge must not recreate an extension storage batch or
  become an alternate telemetry owner.
- External metrics, logs, and traces must never pass through Phoenix.

MinIO/S3 replication testing is explicitly outside this correction series.
`timeless-libsql` stores durable virtual-table state in ordinary SQLite shadow
tables inside the database. Replication, bottomless storage, and file shipping
remain host/operator concerns and can be tested independently later.

## Session C0 — boundary inventory and baselines

- Record the exact branch heads and Stack lockfile revisions before changes.
- Trace every production ingestion, scrape, query, maintenance, and shutdown
  path across metrics, logs, and traces.
- Classify every Elixir participant as control plane, telemetry origin/export
  bridge, or incorrect data-plane ownership.
- Capture the existing Prometheus scrape correctness, throughput, allocation,
  request-tail, durability, and storage baselines using the same fixtures for
  the replacement.
- Pin regressions proving external ingestion reaches the three Rust listeners
  directly and never Phoenix.

Exit criterion: the checked inventory accounts for every process, queue,
parser, batch, socket, and database owner; the replacement baselines and exact
fixtures are reproducible.

## Session C1 — Rust-owned Prometheus scraping and parsing

- Move scrape scheduling, target HTTP collection, response limits, parsing,
  target-label injection, scrape health, cancellation, and retry accounting
  into the Rust metrics process.
- Keep target CRUD and policy in Phoenix. Add a versioned authenticated control
  contract for Phoenix to replace the Rust target set atomically; configuration
  must survive restart through the control plane without making Phoenix a
  telemetry owner.
- Feed raw exposition bytes directly into the existing
  `/api/v1/import/prometheus` and `timeless-core` fused parser path. Do not
  materialize per-sample Elixir maps and do not re-encode scrapes as
  VictoriaMetrics JSON.
- Disable and remove `PrometheusCollector` regex parsing from Rust mode. The
  embedded rollback mode may retain its historical implementation only behind
  an explicit mode gate.
- Remove the legacy `/scrape-targets` UI mismatch by wiring that surface to the
  Phoenix control model used by the Rust scraper or hiding it until supported.
- Revisit parser behavior inherited from the BEAM boundary. Add exact
  regressions for escaped labels, explicit timestamps, missing timestamps,
  target-label precedence, duplicate labels, malformed/partial bodies,
  `NaN`, positive/negative infinity, CRLF, large bodies, cancellation, slow
  targets, authentication, and TLS errors.
- Measure completed durable samples, scrapes/s, points/s, parse and ingest
  p50/p95/p99, allocations/RSS HWM, response bytes, WAL HWM, and exact storage
  parity against the baseline.

Exit criterion: no Rust-mode Prometheus scrape is parsed in Elixir; the Rust
process owns the complete scrape-to-storage path; target administration and
health work through Phoenix; correctness and resource gates pass without a
silent legacy fallback. **Satisfied:** `timeless-libsql`
`afde954` provides the Rust controller/parser path and authenticated target
replacement; `timeless_ui` `7a8d3f3`/`83db76e` persists and synchronizes targets,
skips duplicate Rust-mode Poller jobs, and retains embedded parsing only behind
the explicit rollback mode. Rust and UI unit suites pass.

## Session C2 — remove storage-shaped batching from BEAM bridges

- Remove `TimelessUI.LogsDataPlane.Buffer` as an 8,192-entry duplicate of the
  extension's authoritative log batch in Rust mode.
- Preserve collection of Phoenix's own Logger events through a minimal bounded
  export bridge with explicit backpressure/drop telemetry. Rust alone owns the
  8,192-entry storage batch, compression, and flush policy.
- Audit the Phoenix OpenTelemetry exporter under the same rule: the standard
  SDK export batch is a transport envelope; it must not create an alternate
  span store or extension-sized storage batch.
- Keep external log and OTLP ingestion direct to Rust and pin that routing in
  integration tests.
- Revalidate graceful drain, forced termination, disconnected Rust children,
  logger recursion avoidance, queue bounds, exact completed work, and process
  reaping.

Exit criterion: the only Elixir participation in logs/traces ingestion is the
minimal export of telemetry that originates inside the BEAM; no BEAM queue
claims or duplicates the extension's 8,192-entry storage policy.
**Satisfied for the Logger bridge:** `timeless_ui` `9a745c6` bounds the BEAM
transport queue at 256 entries and leaves batching/compression/storage to Rust.
The OTEL exporter remains a transport envelope and is covered by the existing
trace data-plane contract; a final mixed-workload gate remains in C5.

## Session C3 — current TimelessUI and TimelessCanvas

- Reconcile the latest `timeless_ui` main-line work into
  `release/rust-telemetry-data-plane`, including the generated icon catalog,
  without losing the Rust data-plane adapters, authentication, process
  supervision, or backup work.
- Update `timeless_canvas` from the stale Stack lock revision to the intended
  current revision, including post-0.5.0 hardening, load work, and clipboard
  fixes.
- Pin both dependencies explicitly and refresh `timeless_stack/mix.lock`; do
  not rely on an unqualified moving Git dependency for a release artifact.
- Rebuild static assets and run UI unit/integration tests, Canvas tests and
  browser E2E, Stack tests, authentication/control reconnect tests, and the
  three-signal release smoke gate.
- Verify dashboard/Canvas historical reads still use the Rust owners and that
  unsupported surfaces are hidden or fail explicitly without fallback.

Exit criterion: the Stack release reproducibly contains the selected current
UI and Canvas commits, all assets and tests pass, and every telemetry surface
uses the corrected Rust/control-plane boundary.
**Satisfied:** UI icon catalog commit `83db76e170add578a34881415083d2e099242423`
is on the release branch; Stack pins it and Canvas
`72636bfd8120926679ce4c538b213e7db01a950` in `mix.lock`. Clean dependency and
browser gates are recorded in C5.

## Session C4 — trace fidelity wording and contract audit

- Replace ambiguous claims of "complete OTLP fidelity" with an exact field
  inventory.
- Verify conversion never blanks a field present in legacy TimelessTraces
  storage and document fields that the old format never retained.
- Decide explicitly whether links, tracestate, trace flags, dropped counts,
  and remote-parent state belong to this release's supported stored model. If
  they do, add them additively to the extension/API and exact ingest,
  migration, cold-reopen, query, Jaeger/OTLP, backup, and rollback regressions.
- Never synthesize unavailable legacy values and never label absence as
  successful preservation.

Exit criterion: implementation, migration validation, compatibility docs, and
UI/API responses agree on one exact trace-fidelity contract with no overclaim.
**Satisfied:** `timeless_traces` `5d38b65` adds the checked field inventory and
explicitly documents unsupported links, tracestate, flags, remote-parent state,
schema URLs, and dropped counts without synthesizing values.

## Session C5 — corrected release gate

- Run clean tests and strict linting for every changed repository.
- Repeat the relevant real-extension contracts, shutdown/restart faults,
  browser E2E, packaging/install checks, and sustained mixed workload using
  the exact updated artifact identity.
- Record completed durable work, query and scrape p50/p95/p99, storage, WAL,
  RSS HWM, queues, restart behavior, and exact response/storage parity.
- Update the compatibility statement, operations guide, artifact inventory,
  checksums, evidence, and release handoff from the new exact heads.

Exit criterion: every correction-session criterion passes from clean clones;
the checked evidence identifies the exact UI, Canvas, Stack, signal, and native
heads; only then may the release verdict be restored. **Not yet satisfied:**
the current gate is recorded in
`docs/2026-08-02_rust_data_plane_c5_gate.md`; extension-backed contracts and
Canvas browser E2E still require their native/browser environments.

## Commit policy

Commit and push each successful correction session directly to the existing
release-promotion branches. Do not open pull requests and do not merge to
main. If an optimization or boundary design fails, record and revert it, then
continue independent correction work.
