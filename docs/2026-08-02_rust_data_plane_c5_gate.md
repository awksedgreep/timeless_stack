# Corrected data-plane release gate

Date: 2026-08-02

## Exact heads

- Stack: `326ad30`
- UI promotion branch: `83db76e170add578a34881415083d2e099242423`
- Canvas: `72636bfd812092667ce9c4c538b213e7db01a950`
- metrics/libSQL promotion branch: `afde954`
- traces promotion branch: `5d38b65`

## Executed gates

- `timeless-libsql/servers`: `cargo test -p timeless-metrics-api` — 19 tests
  passed; 10 extension-backed storage contracts remain ignored because this
  checkout does not contain a built `timeless_ext` shared library.
- `timeless_ui`: `mix test` — 112 passed, 1 skipped. The existing restart
  fixture logs an expected child exit 137 while the suite remains green.
- `timeless_canvas`: `mix test` — 258 passed, 15 tagged `:e2e` excluded.
- `timeless_traces`: `mix test` — 201 passed.
- `timeless_stack`: `mix deps.get && mix test` — 37 passed.

## Evidence and limits

The Rust Prometheus unit path covers raw exposition decoration, validation,
version idempotence, authenticated target replacement, and parser handoff.
The rich trace contract has an explicit supported/unsupported field inventory.
MinIO/S3 replication is intentionally not part of this gate; the SQLite/WAL
file remains an operator-owned replication concern.

## Verdict

The boundary corrections are implemented and pushed, but the final production
release gate is **not yet green** until a clean environment builds the
`timeless_ext` library and runs the 10 ignored storage contracts, and Canvas
browser E2E is run with its browser sidecar. No merge to `main` is authorized
by this document. The promotion branches are usable for that final validation.
