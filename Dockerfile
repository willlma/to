# Both stages use Alpine/musl. Match the runtime Alpine version to the builder.
ARG ELIXIR_IMAGE=elixir:1.18.4-otp-27-alpine
ARG ALPINE_VERSION=3.24
FROM ${ELIXIR_IMAGE} AS build

RUN apk add --no-cache build-base git sqlite-dev
WORKDIR /app
ENV MIX_ENV=prod \
    EXQLITE_USE_SYSTEM=1 \
    EXQLITE_SYSTEM_CFLAGS=-I/usr/include \
    EXQLITE_SYSTEM_LDFLAGS="-L/usr/lib -lsqlite3"

RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod && mix deps.compile
COPY lib lib
COPY priv priv
COPY assets assets
RUN mix compile && mix assets.setup && mix assets.deploy && mix release

FROM alpine:${ALPINE_VERSION} AS runtime
RUN apk add --no-cache ca-certificates libstdc++ ncurses-libs openssl sqlite-libs su-exec \
    && mkdir /data
WORKDIR /app
COPY --from=build --chown=nobody:nobody /app/_build/prod/rel/to ./
ENV PHX_SERVER=true PORT=8080 DATABASE_PATH=/data/to.db LANG=C.UTF-8
EXPOSE 8080
# A newly mounted Fly volume belongs to root; only initialization needs root.
CMD ["sh", "-c", "chown nobody:nobody /data && exec su-exec nobody:nobody /app/bin/to start"]
