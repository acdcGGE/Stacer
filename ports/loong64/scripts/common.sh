#!/usr/bin/env bash
# Shared paths for all port scripts. Source this file, do not execute it.
PORT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../meta.env
source "$PORT_ROOT/meta.env"

TRIPLET="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || true)"
[[ -n "$TRIPLET" ]] || TRIPLET="$TARGET_TRIPLET_DEFAULT"

DEPS_DIR="$PORT_ROOT/.deps"
STAGE_USR="$DEPS_DIR/root/usr"
CACHE_DIR="$PORT_ROOT/.cache"
SRC_DIR="${SRC_DIR:-$CACHE_DIR/Stacer}"
BUILD_DIR="${BUILD_DIR:-$SRC_DIR/build}"
DIST_DIR="${DIST_DIR:-$PORT_ROOT/dist}"
JOBS="${JOBS:-$(nproc)}"
