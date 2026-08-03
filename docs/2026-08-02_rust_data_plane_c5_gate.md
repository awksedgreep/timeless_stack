# Corrected data-plane release gate

Date: 2026-08-02

## Exact heads

- Stack: `326ad30`
- UI promotion branch: `83db76e170add578a34881415083d2e099242423`
- Canvas: `72636bfd812092667ce9c4c538b213e7db01a950`
- metrics/libSQL promotion branch: `afde954`
- traces promotion branch: `5d38b65`
- native extension artifact: `afde9543f5e78fcb02375c96e1b741421c53237d`

## Executed gates

- `timeless-libsql/servers`: with a freshly built extension,
  `cargo test --workspace --manifest-path servers/Cargo.toml -- --include-ignored`
  passed all extension-backed metrics, logs, and traces contracts.
- `timeless_ui`: `mix test` — 112 passed, 1 skipped. The existing restart
  fixture logs an expected child exit 137 while the suite remains green.
- `timeless_canvas`: `mix test` — 258 passed, 15 tagged `:e2e` excluded.
- `timeless_traces`: `mix test` — 201 passed.
- `timeless_stack`: `mix deps.get && mix test` — 37 passed.
- `timeless-libsql/tests/cli.sh` — completed all extension CLI, rollback,
  pushdown, and oracle sections successfully.
- `timeless_canvas`: `mix test.e2e` — 15 browser tests passed.
- `cargo build --release --locked --workspace` and strict Clippy — passed.
- `tools/package_release.py --target x86_64-unknown-linux-gnu` — produced and
  checksum-verified the archive
  `f610b3f389b46fabf1b711337cd81f2fdd2bcdc588eef898df1f6744ce0b035f`.
  Temporary-prefix install and uninstall both passed without touching data.
- `tools/production_gate.py --mode short` — passed 120 seconds with all three
  signal owners, 12 scheduled fault events, zero workload errors, and exact
  final barriers. Each signal completed 30,784 durable records at 256.53
  records/s. Query p95s were metrics 1.40–2.74 ms, logs 2.36–57.87 ms, and
  traces 1.27–9.77 ms; RSS HWM was 13,756 KiB, 45,008 KiB, and 59,284 KiB.

## Evidence and limits

The Rust Prometheus unit path covers raw exposition decoration, validation,
version idempotence, authenticated target replacement, and parser handoff.
The rich trace contract has an explicit supported/unsupported field inventory.
MinIO/S3 replication is intentionally not part of this gate; the SQLite/WAL
file remains an operator-owned replication concern.

## Verdict

The correction sessions are complete and the final gate is green for the
validated Linux artifact. No merge to `main` is authorized by this document;
the promotion branches remain the release candidates. A longer two-hour-per-
signal production soak remains a release-operations recommendation, not an
unmet boundary-correction criterion for this session.
