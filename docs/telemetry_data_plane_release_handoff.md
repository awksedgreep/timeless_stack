# Rust/libSQL telemetry data-plane release handoff

Date: 2026-08-02
Release line: `0.3.0` native data plane / Stack `0.6.11`
Promotion branch: `release/rust-telemetry-data-plane`

## Release verdict

The boundary corrections are implemented on the promotion branches. The
validated Linux release gate is green; its exact evidence is recorded in
[`2026-08-02_rust_data_plane_c5_gate.md`](2026-08-02_rust_data_plane_c5_gate.md).
The former Rust-mode Elixir scrape parser, storage-shaped BEAM batch, stale UI
and Canvas pins, and ambiguous trace-fidelity wording are corrected:

- Rust-mode Prometheus scraping now uses the Rust controller and fused parser.
- The BEAM Logger bridge is bounded to transport-only batches below 8,192.
- Stack pins the selected current TimelessUI and TimelessCanvas revisions.
- Trace fidelity has an exact supported/unsupported field inventory.

The sequential correction plan and exit criteria are checked in at
[`2026-08-02_rust_data_plane_boundary_corrections.md`](2026-08-02_rust_data_plane_boundary_corrections.md).
MinIO/S3 replication testing is not part of that plan; host-level SQLite/libSQL
replication remains independently testable by operators and direct users.

The prior sustained gate ran from
`timeless-libsql` `bab775035785b78e0d9879b7d871bbd938e92991` for 9,602.37
seconds, or 8.00197 aggregate signal-hours, and recorded all 12 fault events as
passed with no workload errors.

The checked evidence is
`timeless-libsql/docs/evidence/2026-08-02_release_gate_bab7750.json`, SHA-256
`8d3472a3b7843b759e1a1fda830c2668b89da5c96ffa1025aa2069c10158d11d`.

## Compatibility and migration statement

The default Timeless Stack installation sets `TIMELESS_DATA_PLANE=rust` and
runs three separate Rust HTTP owners backed by the public `timeless-libsql`
extension. Phoenix remains the control plane. It owns users, sessions, token
issuance, authorization policy, tenancy, configuration, cluster
administration, Canvas/dashboard state, and process supervision; it never
opens a telemetry database.

Fresh installations create libSQL virtual tables. Existing installations are
detected before readiness as fresh, valid libSQL, legacy Rust storage,
resumable migration, completed cutover, incompatible version, corruption, or
ambiguous dual stores. Legacy storage is converted side-by-side through the
extension's public batch/SQL interface under exclusive ownership. The source
stays immutable; a versioned journal resumes bounded batches; cold validation
checks exact signal semantics; flush/maintenance/checkpoint/reopen completes;
and one atomic rename cuts over. Failure is closed and leaves the source
usable by the previous release. No legacy source is deleted automatically.

The three OTP signal libraries remain available as migration/rollback and
standalone embedded-library compatibility surfaces. Their standalone engine
selectors are not another production owner: Stack Rust mode starts them in
external mode. In particular, the standalone `timeless_metrics` library keeps
its historical embedded Rust default in this release, while a normal Stack
installation defaults to the external Rust/libSQL data plane.

The exact supported Metrics/Prometheus/Victoria, LogsQL, OTLP, Jaeger,
dashboard, and PromQL subset is frozen in
[`telemetry_data_plane_compatibility.md`](telemetry_data_plane_compatibility.md).
Anything absent from that document fails explicitly and never falls through
to Rocket, another signal, or an embedded owner.

## Artifact inventory

The exact clean CI artifact source is
`bab775035785b78e0d9879b7d871bbd938e92991`. Each native archive contains the
three versioned signal binaries, the matching extension, internal
`SHA256SUMS`, build/capability manifest, SPDX SBOM, third-party/project license
notices, and install/uninstall scripts.

| target | archive SHA-256 |
|---|---|
| `aarch64-apple-darwin` | `862979f12e692533ba0e10c4308727bc68d6d71ad3a30d5628b516f28e541760` |
| `aarch64-unknown-linux-gnu` | `3b1436cee660ab2330adc920806b6499dd59e449e4ae37c35823508b9f0e4813` |
| `x86_64-apple-darwin` | `fed469529d14e60a54c5273f502d4d52e8a56e8f0d850570d84b3060b15dbf66` |
| `x86_64-unknown-linux-gnu` | `5350fc93b729b36c85946752f661ee4d221044c1caee5443d42747357653118c` |

GitHub Actions run `30769695085` built all four archives on native supported
runners and verified the combined checksum set. Run `30769695093` passed the
clean root/server unit, contract, real-extension, strict Clippy, and two-minute
mixed production fault gates.

## Operator handoff

Use [`telemetry_data_plane_operations.md`](telemetry_data_plane_operations.md)
for exact installation, fresh readiness, coordinated online backup, offline
restore, upgrade/interruption behavior, both rollback meanings, re-upgrade,
and explicit post-window legacy cleanup. The short form is:

1. Verify the published archive checksum and install the immutable native
   bundle without removing the previous one.
2. Create and verify a coordinated backup before upgrade.
3. Stop the whole release and confirm every old owner exited.
4. Start the new release and wait for authenticated combined readiness. A
   migration state is not ready.
5. Run metric, log, and rich-trace semantic smoke queries.
6. Retain the previous artifact, verified backup, and immutable legacy source
   through the rollback window ending at `0.9.0`.

Rollback to the untouched pre-cutover timeline is offline-only and requires
`TIMELESS_DATA_PLANE=legacy` plus
`TIMELESS_LEGACY_ROLLBACK_ACK=retain-legacy-until-0.9.0` on the previous
compatible release. It intentionally excludes post-cutover writes. Exact
rollback with post-cutover writes means restoring a verified Rust/libSQL
backup into a separate directory. Never alternate owners on one directory.

## Declared limits and operational alerts

The shipped maximums are a 10 MiB request and decompressed body, 16 MiB
response, 100,000 query rows, 30-second request duration, 64 concurrent
requests per token, one-second admission wait, 256-request writer queues, and
two SQLite readers per signal. Claims may lower but cannot raise these values.

Alert when authenticated readiness is false, restart count grows, a migration
phase stops advancing, a queue remains nonzero, checkpoint/backup/maintenance
errors increase, WAL approaches 512 MiB, RSS approaches 512 MiB for metrics or
logs / 768 MiB for traces, warm per-process RSS slope exceeds 16 MiB/hour,
disk free space approaches migration/backup headroom, or query p99 approaches
the documented 10-second hard release ceiling. Treat corrupt, incompatible,
ambiguous, disk-full, read-only, owner-conflict, and capability errors as
closed operational incidents.

The slope alert applies to a generation alive for at least two hours and must
be interpreted with retained live-set growth. The release fault schedule kept
each generation shorter; trace RSS nevertheless remained bounded at 206,236
KiB while its live index reached 2,457,600 spans. Short-generation trace slopes
remain diagnostic evidence, not a claim of zero growth.

## Honest tradeoffs and remaining blockers

- Rich logs retain exact eight-level severity, microseconds, and typed nested
  metadata, but their earlier fixed POC comparison showed lower maximum write
  throughput and higher HWM than the lossy flat format. Fidelity wins; the
  regression remains documented.
- Trace duration-miss queries remain decode-bound and have the widest known
  trace tail. The supported path is exact, bounded, and substantially below
  the release ceiling, but it is not represented as free.
- The PromQL and LogsQL surfaces are intentionally narrower than their full
  languages. Unsupported syntax is an explicit compatibility error.
- Selecting the retained legacy rollback source after cutover creates a
  divergent timeline by definition; use verified backup restore when
  post-cutover writes must survive rollback.
- Logical optimize is not physical vacuum. Production does not run a blocking
  full `VACUUM` against an active owner; page/freelist reuse and physical HWM
  remain separate measurements.
- The validated gate is a Linux x86_64 artifact. Repeat the packaging and
  browser matrix for each additional release target before publishing it.
- The evidence gate is a 120-second short soak. Run the existing two-hour per
  signal production soak when scheduling the final production rollout.
