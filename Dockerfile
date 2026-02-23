# Stage 1: Build
FROM docker.io/hexpm/elixir:1.18.3-erlang-27.3.4-debian-bookworm-20250428 AS builder

RUN apt-get update && \
    apt-get install -y git build-essential cmake && \
    rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Copy all sibling repos needed by path deps
WORKDIR /build
COPY timeless_metrics/ timeless_metrics/
COPY timeless_ui/ timeless_ui/

# Build the stack
WORKDIR /build/timeless_stack
COPY timeless_stack/mix.exs timeless_stack/mix.lock ./

# Rewrite path deps to use /build/ prefix for container context
# Also ensure hackney is present for Swoosh
RUN sed -i 's|path: "\.\./timeless_metrics"|path: "/build/timeless_metrics"|' mix.exs && \
    sed -i 's|path: "\.\./timeless_ui"|path: "/build/timeless_ui"|' mix.exs && \
    sed -i 's|{:timeless_ui, path: "/build/timeless_ui"}|{:timeless_ui, path: "/build/timeless_ui"},\n      {:hackney, "~> 1.20"}|' mix.exs

# Copy config BEFORE deps so compile_env values are set
COPY timeless_stack/config config
RUN sed -i 's|Path.expand("../../timeless_ui/assets", __DIR__)|"/build/timeless_ui/assets"|' config/config.exs && \
    sed -i 's|Path.expand("../../timeless_ui", __DIR__)|"/build/timeless_ui"|' config/config.exs

RUN mix deps.get --only prod
RUN mix deps.compile

COPY timeless_stack/lib lib

# Heroicons is referenced from timeless_ui/deps/ by the tailwind plugin,
# but mix deps.get fetches it into timeless_stack/deps/. Symlink it.
RUN mkdir -p /build/timeless_ui/deps && \
    ln -sf /build/timeless_stack/deps/heroicons /build/timeless_ui/deps/heroicons

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
