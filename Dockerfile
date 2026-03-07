# Stage 1: Build
FROM docker.io/hexpm/elixir:1.18.3-erlang-27.3.4-debian-bookworm-20250428 AS builder

RUN apt-get update && \
    apt-get install -y git build-essential cmake && \
    rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

WORKDIR /build/timeless_stack
COPY timeless_stack/mix.exs timeless_stack/mix.lock ./

# Copy config BEFORE deps so compile_env values are set
COPY timeless_stack/config config

RUN mix deps.get --only prod
RUN mix deps.compile

COPY timeless_stack/lib lib

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
    apt-get install -y libstdc++6 openssl libncurses6 locales curl && \
    rm -rf /var/lib/apt/lists/* && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app

COPY --from=builder /build/timeless_stack/_build/prod/rel/timeless_stack ./

VOLUME /data

# Metrics, Logs, Traces, UI
EXPOSE 8428 9428 10428 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD curl -sf http://localhost:8428/health && \
      curl -sf http://localhost:9428/health && \
      curl -sf http://localhost:10428/health

ENTRYPOINT ["bin/timeless_stack"]
CMD ["start"]
