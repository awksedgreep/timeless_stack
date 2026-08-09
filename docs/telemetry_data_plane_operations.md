# Rust/libSQL telemetry data-plane operations

Status: release-promotion branch, Session 6

These procedures cover the three signal-specific Rust owners. Phoenix remains
the control plane and must be the only process that starts or stops them. Never
open, copy, vacuum, or migrate an active telemetry database directly.

## Artifact inventory and installation

One native `timeless-telemetry-data-plane-0.3.0-<target>.tar.gz` bundle contains:

- `bin/timeless-metrics-api`, `bin/timeless-logs-api`, and
  `bin/timeless-traces-api`;
- `lib/libtimeless_ext.so` on Linux or `lib/libtimeless_ext.dylib` on macOS;
- `artifact-manifest.json`, `SBOM.spdx.json`,
  `THIRD_PARTY_LICENSES.txt`, `licenses/timeless-libsql-MIT.txt`, and
  `SHA256SUMS`; and
- `install.sh` and `uninstall.sh`.

Supported targets are Linux x86-64/arm64 and macOS Intel/Apple Silicon. The
bundle is native: the installer rejects a different host target. Verify the
published archive checksum before extraction, then run:

```sh
tar -xzf timeless-telemetry-data-plane-0.3.0-<target>.tar.gz
cd timeless-telemetry-data-plane-0.3.0-<target>
sudo ./install.sh --prefix /opt/timeless
```

The installer verifies every internal checksum and binary build identity. It
places an immutable versioned tree under
`/opt/timeless/telemetry-data-plane/` and atomically switches links in
`/opt/timeless/bin` and `/opt/timeless/lib`. Existing releases are retained so
an operator can switch back. Data and configuration paths are not created or
changed.

Set the Stack release's `RELEASE_ROOT=/opt/timeless`. Its startup preflight
requires the binaries and extension to exist, have appropriate execute/read
permissions, agree on capability/schema/minimum versions and build identity,
and have writable state directories. Linux packages and containers must
provide `/usr/bin/kill`; the shipped container installs it from `procps`.

Clean removal of one installed version is:

```sh
sudo /opt/timeless/telemetry-data-plane/<release-id>/uninstall.sh \
  --prefix /opt/timeless
```

This removes only links owned by that release and, unless `--keep-artifact` is
used, its immutable artifact directory. It never removes telemetry data,
configuration, backups, or legacy rollback sources. There is no automatic
data cleanup. Legacy cleanup is a separate, explicit post-rollback-window
operation described below.

## Fresh start and readiness

The production default is `TIMELESS_DATA_PLANE=rust`. With an empty data
directory, start the Stack release and wait for all of these to succeed:

```sh
curl -f http://127.0.0.1:8428/live
curl -f http://127.0.0.1:9428/live
curl -f http://127.0.0.1:10428/live
curl -f http://127.0.0.1:4000/
```

`/live` is deliberately unauthenticated and only proves that the local owner
is serving. `/ready`, `/health`, signal stats, ingestion, and query routes
require a Phoenix-issued credential. The authenticated Phoenix telemetry
administration endpoint is the authoritative combined state; it reports
migration phase/progress, source identity, target path, and process readiness.
Do not send production traffic until all three signals are ready.

## Coordinated online backup

Choose a new absolute destination whose parent is on durable storage. The
destination itself must not exist. From a running release:

```sh
bin/timeless_stack rpc '
case TimelessStack.backup("/srv/timeless-backups/2026-08-02T2100Z") do
  {:ok, report} -> IO.inspect(report, pretty: true)
  {:error, reason} -> IO.inspect(reason, label: "backup failed"); System.halt(1)
end
'
```

The call drains the bounded Phoenix logs buffer. Each Rust owner then places a
barrier behind admitted writes, flushes the extension's authoritative batch,
runs the signal's bounded optimize/rollup work, checkpoints the WAL, and uses
SQLite's online-backup API. A staging directory is checksummed, reopened, and
published atomically. Concurrent writes accepted after an owner's barrier are
outside that owner's snapshot; the returned per-signal reports define the
durable cut.

The operation fails closed if migration is active, an owner is not ready,
optimization/checkpoint cannot finish, the destination exists, a retained
legacy source changed, control state cannot be copied, or verification fails.
No partial staging directory is promoted. Never use filesystem copy on a live
database or its WAL.

Verify an existing backup without opening active telemetry storage:

```sh
bin/timeless_stack eval '
case TimelessStack.Backup.verify("/srv/timeless-backups/2026-08-02T2100Z") do
  {:ok, manifest} -> IO.inspect(manifest, pretty: true)
  {:error, reason} -> IO.inspect(reason, label: "verification failed"); System.halt(1)
end
'
```

Retain at least one verified backup outside the telemetry data filesystem.
During the rollback window the backup includes the immutable legacy source and
its source manifest; losing both the live retained source and all backups
removes the legacy rollback option.

## Offline restore drill

Stop the complete Stack release and verify the three Rust child PIDs have
exited. Restore only into a new or empty directory, never over the active
directory:

```sh
bin/timeless-restore-backup \
  /srv/timeless-backups/2026-08-02T2100Z \
  /srv/timeless-restore-drill
```

Restore verifies the full checksum inventory, recreates each signal's exact
target filename, restores control/auth and retained legacy sources, runs
SQLite `quick_check` plus the signal schema ledger, fsyncs copied files, and
atomically publishes the new data tree. Point a scratch release at the restored
tree and run authenticated metric, log, and trace semantic queries before
declaring the backup usable.

## Upgrade, interruption, rollback, and re-upgrade

1. Create and verify a coordinated backup.
2. Stop the complete release; confirm no signal owner remains.
3. Install the new native bundle without removing the previous version.
4. Start the new Stack release. Startup detects fresh, valid libSQL, legacy,
   resumable migration, completed cutover, incompatible, corrupt, and ambiguous
   dual-store states before mutation.
5. Wait for authenticated combined readiness and run semantic smoke queries.
6. Keep the previous bundle, verified backup, and immutable legacy sources for
   the entire rollback window.

Power loss or process death during conversion is recovered through the
versioned migration journal. Retry the same release; it validates the immutable
source manifest and resumes idempotently. An incompatible binary/extension,
unsupported schema downgrade, corrupt database, changed source, insufficient
space, or ambiguous stores fails before ownership/cutover and leaves the source
usable by the previous release.

There are two rollback meanings:

- To return to the untouched pre-cutover timeline, stop the Stack and use
  `TIMELESS_DATA_PLANE=legacy` with
  `TIMELESS_LEGACY_ROLLBACK_ACK=retain-legacy-until-0.9.0` on the previous
  compatible release. Post-cutover writes are intentionally absent.
- To preserve post-cutover writes, stop the Stack, restore the most recent
  verified release backup to a separate directory, and start a compatible
  Rust/libSQL artifact against that directory.

Never alternate owners against one directory. A re-upgrade starts from either
the untouched retained legacy source or a separately restored libSQL data
tree, never from a mixed directory. Unsupported downgrade must be treated as
a closed compatibility error; do not edit the schema ledger to force it.

## Explicit legacy-source cleanup after the rollback window

Do not perform this procedure during the first-release rollback window. It is
eligible only after every node is on a release where the documented legacy
rollback selector has expired, the libSQL timeline has been accepted, and at
least one verified backup containing the retained source exists outside the
live data filesystem. Cleanup is irreversible from the live tree; recovery
afterward requires that backup.

1. Create a coordinated backup and run `TimelessStack.Backup.verify/1` as
   shown above. Record the backup path and verification result.
2. Stop the complete Stack release and confirm the Phoenix and all three Rust
   owner PIDs have exited.
3. Read each signal's `source_manifest_digest` from the last authenticated
   readiness/stats report or the verified backup manifest. Compare it with
   the final retained-source manifest. Do not proceed if either value is
   absent or differs.
4. Require a second operator to confirm the exact signal, data directory,
   backup path, and digest. There is deliberately no wildcard/all-signals
   cleanup command.
5. Run one explicit command per confirmed signal, substituting the recorded
   64-character digest. The function re-reads and hashes the source, requires
   completed cutover, checks the digest again under exclusive ownership,
   removes only the manifest-listed legacy source, and records
   `source_retained=0` in the cutover ledger:

   ```sh
   TIMELESS_EXT_PATH=/opt/timeless/lib/libtimeless_ext.so \
   bin/timeless_stack eval '
   root = System.get_env("TIMELESS_DATA_DIR", "/data")
   extension = System.fetch_env!("TIMELESS_EXT_PATH")
   digest = "REPLACE_WITH_CONFIRMED_METRICS_SOURCE_MANIFEST_DIGEST"
   IO.inspect(
     TimelessMetrics.ReleaseStartup.cleanup_legacy(
       Path.join(root, "metrics"), digest, extension_path: extension
     )
   )
   '
   ```

   For logs or traces, replace the module with
   `TimelessLogs.ReleaseStartup` or `TimelessTraces.ReleaseStartup`, replace
   the directory name, and supply that signal's own digest.
6. Restart the release, require all three signals to report ready, create a
   new coordinated backup, and rerun semantic smoke queries.

Never delete `rust_engine/`, `blocks/`, legacy SQLite indexes, cutover ledgers,
or migration directories with filesystem commands. If cleanup fails, leave
the tree stopped and use the actionable error; do not edit a manifest or
ledger to force it.
