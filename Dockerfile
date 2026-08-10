# Stage 1: Build
FROM docker.io/hexpm/elixir:1.18.3-erlang-27.3.4-debian-bookworm-20250428 AS builder

RUN apt-get update && \
    apt-get install -y git build-essential cmake curl && \
    rm -rf /var/lib/apt/lists/*

# Install Rust toolchain for tms_engine NIF
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

ARG TIMELESS_BUILD_COMMIT

# The release tag the data plane was built from, recorded as a label so the
# image reports it directly. The commit alone is unreadable — the SHA this
# build previously froze on gave no hint it was three minor versions behind.
ARG TIMELESS_BUILD_RELEASE
LABEL org.opencontainers.image.base.name="timeless-libsql:${TIMELESS_BUILD_RELEASE}"

# Build the released storage extension and the three signal-specific data
# planes from the timeless-libsql release resolved at build time. The
# container never reconstructs these binaries from POC sources.
WORKDIR /build/timeless-libsql
COPY timeless-libsql/Cargo.toml timeless-libsql/Cargo.lock ./
COPY timeless-libsql/crates crates
COPY timeless-libsql/servers/Cargo.toml timeless-libsql/servers/Cargo.lock servers/
COPY timeless-libsql/servers/crates servers/crates
RUN test -n "${TIMELESS_BUILD_COMMIT}" && \
    TIMELESS_BUILD_COMMIT="${TIMELESS_BUILD_COMMIT}" cargo build --locked --release -p timeless-ext && \
    TIMELESS_BUILD_COMMIT="${TIMELESS_BUILD_COMMIT}" cargo build \
      --manifest-path servers/Cargo.toml --locked --release --workspace

WORKDIR /build/timeless_stack
COPY timeless_stack/mix.exs timeless_stack/mix.lock ./

# Copy config BEFORE deps so compile_env values are set
COPY timeless_stack/config config

RUN mix deps.get --only prod
RUN mix deps.compile

COPY timeless_stack/lib lib
COPY timeless_stack/rel rel

# Heroicons is a dep of timeless_ui but gets fetched into the stack's deps/.
# Tailwind expects it at deps/timeless_ui/deps/heroicons, so symlink it.
RUN mkdir -p deps/timeless_ui/deps && \
    ln -sf /build/timeless_stack/deps/heroicons deps/timeless_ui/deps/heroicons && \
    ln -sf /build/timeless_stack/deps/timeless_canvas deps/timeless_ui/deps/timeless_canvas

# Build assets
RUN mix assets.setup
RUN mix assets.deploy

RUN mix compile
RUN mix release

# Stage 2: Runtime (trixie for GLIBC >= 2.38 needed by ex_openzl NIF)
FROM docker.io/debian:trixie-slim

RUN apt-get update && \
    apt-get install -y libstdc++6 openssl libncurses6 locales curl procps && \
    rm -rf /var/lib/apt/lists/* && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8
ENV RELEASE_ROOT=/app
ENV TIMELESS_TELEMETRY_BIND=0.0.0.0

WORKDIR /app

COPY --from=builder /build/timeless_stack/_build/prod/rel/timeless_stack ./
COPY --from=builder /build/timeless-libsql/servers/target/release/timeless-metrics-api /app/bin/
COPY --from=builder /build/timeless-libsql/servers/target/release/timeless-logs-api /app/bin/
COPY --from=builder /build/timeless-libsql/servers/target/release/timeless-traces-api /app/bin/
COPY --from=builder /build/timeless-libsql/target/release/libtimeless_ext.so /app/lib/

VOLUME /data

# Metrics, Logs, Traces, UI
EXPOSE 8428 9428 10428 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD curl -sf http://localhost:8428/live && \
      curl -sf http://localhost:9428/live && \
      curl -sf http://localhost:10428/live && \
      curl -sf http://localhost:4000 >/dev/null

ENTRYPOINT ["bin/timeless_stack"]
CMD ["start"]
