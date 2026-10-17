#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -f /workspace/.toolchain/activate ]; then source /workspace/.toolchain/activate; fi
mix setup
pnpm install --frozen-lockfile
pnpm exec playwright install chromium --only-shell
