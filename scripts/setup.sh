#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -f /workspace/.toolchain/activate ]; then source /workspace/.toolchain/activate; fi
mix deps.get --check-locked
mix ecto.create
mix ecto.migrate
mix assets.setup
mix assets.build
npm ci --cache "${NPM_CONFIG_CACHE:-$PWD/tmp/npm-cache}" --no-audit --no-fund
