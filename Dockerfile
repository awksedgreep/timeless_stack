# Stage 1: Build
FROM docker.io/elixir:1.18 AS builder

RUN apt-get update && \
    apt-get install -y git build-essential cmake && \
    rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

WORKDIR /app

ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

COPY config config
COPY lib lib
RUN mix compile
RUN mix release

# Stage 2: Runtime
FROM docker.io/debian:trixie-slim

RUN apt-get update && \
    apt-get install -y libstdc++6 openssl libncurses6 locales curl && \
    rm -rf /var/lib/apt/lists/* && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app

COPY --from=builder /app/_build/prod/rel/timeless_stack ./

VOLUME /data

EXPOSE 8428 9428 10428

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -sf http://localhost:8428/health && \
      curl -sf http://localhost:9428/health && \
      curl -sf http://localhost:10428/health

ENTRYPOINT ["bin/timeless_stack"]
CMD ["start"]
