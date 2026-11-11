#!/usr/bin/env bash
# Fetch the exact upstream commit (shallow) into .cache/Stacer.
# Usage: scripts/10-fetch-src.sh [src-dir]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SRC="${1:-$SRC_DIR}"
mkdir -p "$(dirname "$SRC")"

if [[ -d "$SRC/.git" ]]; then
    current="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)"
    if [[ "$current" == "$UPSTREAM_COMMIT" ]]; then
        echo "[src] already at pinned commit ${UPSTREAM_COMMIT:0:12}"
        exit 0
    fi
    echo "[src] existing checkout is at ${current:0:12}; remove $SRC to re-clone." >&2
    exit 1
fi

echo "[src] fetching $UPSTREAM_URL @ ${UPSTREAM_COMMIT:0:12}"
git init -q "$SRC"
git -C "$SRC" remote add origin "$UPSTREAM_URL"
git -C "$SRC" fetch --depth 1 origin "$UPSTREAM_COMMIT" > /dev/null 2>&1
git -C "$SRC" checkout -q FETCH_HEAD
echo "[src] HEAD = $(git -C "$SRC" rev-parse HEAD)"
