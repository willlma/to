#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -f /workspace/.toolchain/activate ]; then source /workspace/.toolchain/activate; fi
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$(pwd)/tmp/cache}"
export MIX_ENV=test PORT=4002
unset PHX_SERVER E2E_SERVER
export E2E_DB_PATH="$(pwd)/tmp/e2e.db"
mkdir -p tmp artifacts/e2e
rm -f "$E2E_DB_PATH" "$E2E_DB_PATH-shm" "$E2E_DB_PATH-wal"
mix ecto.create --quiet
mix ecto.migrate --quiet
mix assets.deploy
export E2E_SERVER=1
exec mix run --no-halt test/support/e2e_server.exs
