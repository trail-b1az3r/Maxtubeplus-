#!/usr/bin/env bash
# Builds and runs the host-side MaxTubePlus core tests (logic only; no device).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/mtp_core_tests"
CC="${CC:-cc}"
"$CC" -std=c99 -D_DEFAULT_SOURCE -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined \
  "$ROOT/MaxTubePlus/Core/MTPCore.c" "$ROOT/Tests/core_tests.c" -o "$OUT"
"$OUT"
