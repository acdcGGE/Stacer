#!/usr/bin/env bash
# Apply every patch in patches/ to the checked-out upstream tree, in order.
# Idempotent: already-applied patches are skipped.
# Usage: scripts/20-apply-patches.sh [src-dir]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SRC="${1:-$SRC_DIR}"
shopt -s nullglob
patches=("$PORT_ROOT"/patches/*.patch)
(( ${#patches[@]} > 0 )) || { echo "ERROR: no patches found" >&2; exit 1; }

for patch in "${patches[@]}"; do
    name="$(basename "$patch")"
    if git -C "$SRC" apply --reverse --check "$patch" 2>/dev/null; then
        echo "[patch] $name : already applied"
        continue
    fi
    git -C "$SRC" apply --check "$patch"
    git -C "$SRC" apply "$patch"
    echo "[patch] $name : applied"
done
