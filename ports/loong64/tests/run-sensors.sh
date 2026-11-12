#!/usr/bin/env bash
# Compile and run the temperature/GPU probe against a built stacer-core.
# Usage: tests/run-sensors.sh <stacer-src-dir> <cmake-build-dir>
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-$REPO_ROOT/.cache/Stacer}"
BUILD="${2:-$SRC/build}"

CORE_LIB="$BUILD/stacer-core/libstacer-core.a"
if [[ ! -f "$CORE_LIB" ]]; then
    echo "ERROR: $CORE_LIB not found. Build Stacer first (./build.sh)." >&2
    exit 1
fi

QT_CFLAGS="$(pkg-config --cflags Qt6Core)"
QT_LIBS="$(pkg-config --libs Qt6Core)"

TMP_BIN="$(mktemp -d)/sensors_probe"
# shellcheck disable=SC2086
g++ -std=c++17 -fPIC -O0 \
    "$REPO_ROOT/tests/sensors_test.cpp" \
    -I"$SRC/stacer-core" \
    -I"$SRC/stacer-core/Info" \
    -I"$SRC/stacer-core/Tools" \
    -I"$SRC/stacer-core/Utils" \
    $QT_CFLAGS \
    "$CORE_LIB" $QT_LIBS \
    -o "$TMP_BIN"

"$TMP_BIN"
rm -f "$TMP_BIN"