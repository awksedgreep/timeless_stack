#!/bin/sh
set -eu

stack=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
workspace=$(CDPATH= cd -- "$stack/.." && pwd)
libsql="$workspace/timeless-libsql"
target=$(rustc -vV | sed -n 's/^host: //p')
case "$target" in
  *-apple-darwin) extension="$libsql/target/debug/libtimeless_ext.dylib" ;;
  *) extension="$libsql/target/debug/libtimeless_ext.so" ;;
esac
temporary=$(mktemp -d -p /tmp timeless-session6.XXXXXX)
container=
cleanup() {
  if [ -n "$container" ]; then
    docker rm -f "$container" >/dev/null 2>&1 || true
  fi
  rm -rf "$temporary"
}
trap cleanup EXIT HUP INT TERM

for repository in timeless-libsql timeless_metrics timeless_logs timeless_traces timeless_ui timeless_stack; do
  branch=$(git -C "$workspace/$repository" branch --show-current)
  test "$branch" = release/rust-telemetry-data-plane || {
    echo "$repository is on unexpected branch $branch" >&2
    exit 1
  }
done

(cd "$libsql" && cargo build --locked)
test -f "$extension"

(cd "$workspace/timeless_metrics" && TIMELESS_EXT_PATH="$extension" mix test test/release_startup_test.exs)
(cd "$workspace/timeless_logs" && TIMELESS_EXT_PATH="$extension" mix test test/timeless_logs/release_startup_test.exs)
(cd "$workspace/timeless_traces" && TIMELESS_EXT_PATH="$extension" mix test \
  test/timeless_traces/legacy_reader_test.exs \
  test/timeless_traces/release_startup_test.exs)

(
  cd "$libsql/servers"
  TIMELESS_EXT_PATH="$extension" TIMELESS_EXT_TEST_PATH="$extension" \
    cargo test --workspace --locked -- --include-ignored
  cargo clippy --workspace --all-targets --locked -- -D warnings
)

(
  cd "$workspace/timeless_ui"
  mix test \
    test/timeless_ui/telemetry_data_plane/process_test.exs \
    test/timeless_ui/application_test.exs \
    test/timeless_ui/metrics_data_plane/client_test.exs \
    test/timeless_ui/logs_data_plane/client_test.exs \
    test/timeless_ui/traces_data_plane/client_test.exs
)
(cd "$stack" && mix test)

dirty_flag=
if [ -n "$(git -C "$libsql" status --porcelain)" ]; then
  dirty_flag=--allow-dirty
fi
python3 "$libsql/tools/package_release.py" --target "$target" --output "$temporary/dist" $dirty_flag
archive=$(find "$temporary/dist" -maxdepth 1 -type f -name '*.tar.gz' -print)
if command -v sha256sum >/dev/null 2>&1; then
  first=$(sha256sum "$archive" | cut -d' ' -f1)
else
  first=$(shasum -a 256 "$archive" | cut -d' ' -f1)
fi
python3 "$libsql/tools/package_release.py" --target "$target" --output "$temporary/dist" $dirty_flag --force
if command -v sha256sum >/dev/null 2>&1; then
  second=$(sha256sum "$archive" | cut -d' ' -f1)
else
  second=$(shasum -a 256 "$archive" | cut -d' ' -f1)
fi
test "$first" = "$second"

bundle=${archive%.tar.gz}
install_root="$temporary/install"
mkdir -p "$install_root/data" "$install_root/config"
printf 'preserve\n' > "$install_root/data/sentinel"
printf 'preserve\n' > "$install_root/config/sentinel"
"$bundle/install.sh" --prefix "$install_root"
installed=$(sed -n '1p' "$install_root/telemetry-data-plane/CURRENT")
"$installed/uninstall.sh" --prefix "$install_root"
test -f "$install_root/data/sentinel"
test -f "$install_root/config/sentinel"

(
  cd "$stack"
  MIX_ENV=prod mix compile --warnings-as-errors
  MIX_ENV=prod mix release --overwrite
  test -x _build/prod/rel/timeless_stack/bin/timeless-restore-backup
)

if [ "${RUN_CONTAINER_DRILL:-0}" = 1 ]; then
  commit=$(git -C "$libsql" rev-parse HEAD)
  tar -C "$workspace" \
    --exclude='*/.git' --exclude='*/target' --exclude='*/_build' \
    --exclude='*/deps' --exclude='*/dist' \
    -cf - timeless_stack timeless-libsql |
    docker build --build-arg "TIMELESS_BUILD_COMMIT=$commit" \
      -f timeless_stack/Dockerfile -t timeless-stack:session6 -

  docker run --rm --entrypoint /bin/sh timeless-stack:session6 -c \
    'test -x /usr/bin/kill &&
     test -x /app/bin/timeless-metrics-api &&
     test -x /app/bin/timeless-logs-api &&
     test -x /app/bin/timeless-traces-api &&
     test -x /app/bin/timeless-restore-backup &&
     test -r /app/lib/libtimeless_ext.so'

  container="timeless-session6-$$"
  docker run -d --name "$container" --tmpfs /data \
    -e SECRET_KEY_BASE=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
    timeless-stack:session6 >/dev/null

  ready=false
  attempts=0
  while [ "$attempts" -lt 60 ]; do
    if [ "$(docker inspect "$container" --format '{{.State.Running}}')" != true ]; then
      break
    fi
    if docker exec "$container" /bin/sh -c \
      'curl -sf http://localhost:8428/live >/dev/null &&
       curl -sf http://localhost:9428/live >/dev/null &&
       curl -sf http://localhost:10428/live >/dev/null &&
       curl -sf http://localhost:4000 >/dev/null'; then
      ready=true
      break
    fi
    attempts=$((attempts + 1))
    sleep 1
  done
  if [ "$ready" != true ]; then
    docker logs "$container"
    exit 1
  fi
  docker stop --time 30 "$container" >/dev/null
  docker rm "$container" >/dev/null
  container=
fi

printf 'session6_release_drill=pass\n'
printf 'artifact_sha256=%s\n' "$second"
printf 'target=%s\n' "$target"
