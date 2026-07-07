#!/usr/bin/env bash
# Top-level test runner: build the rite bundle, run unit tests, then e2e.
#
# Run with: bash tests/run.sh   (or `lgx e2e`)

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

echo "==> Building rite bundle..."
lgx build >/dev/null

echo
echo "==> Unit tests..."
lgx test

echo
echo "==> E2E tests..."
bash tests/e2e.sh

echo
echo "All tests passed."
