#!/usr/bin/env bash
# One-shot reproducible build of Stacer 1.8.0 for loong64 / Deepin 25.
#
#   ./build.sh                 # full clean-ish build into dist/
#   SRC_DIR=/path/to/Stacer ./build.sh   # reuse an existing checkout
#   EXTRA_CMAKE_ARGS="-DCMAKE_CXX_FLAGS=-DSTACER_ENABLE_SVG_ANIMATION" ./build.sh
#
# No root privileges required: missing Qt6 dev packages are staged locally.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/scripts/common.sh"

echo "=== Stacer loong64 port ==="
echo "upstream : $UPSTREAM_URL @ ${UPSTREAM_COMMIT:0:12} ($UPSTREAM_VERSION)"
echo "target   : $(uname -m) / $TRIPLET / $(. /etc/os-release; echo "$PRETTY_NAME")"
echo "jobs     : $JOBS"

"$PORT_ROOT/scripts/00-deps.sh"
# shellcheck source=../.deps/config.env
source "$DEPS_DIR/config.env"

"$PORT_ROOT/scripts/10-fetch-src.sh" "$SRC_DIR"
"$PORT_ROOT/scripts/20-apply-patches.sh" "$SRC_DIR"

# Qt6Config.cmake resolves components relative to the system Qt prefix, so
# both component dirs must be passed explicitly when using a staging prefix.
CHARTS_DIR="$STAGE_PREFIX/lib/$TRIPLET/cmake/Qt6Charts"
LINGUIST_DIR="$STAGE_PREFIX/lib/$TRIPLET/cmake/Qt6LinguistTools"
[[ -f "$CHARTS_DIR/Qt6ChartsConfig.cmake" ]] || CHARTS_DIR="/usr/lib/$TRIPLET/cmake/Qt6Charts"
[[ -f "$LINGUIST_DIR/Qt6LinguistToolsConfig.cmake" ]] || LINGUIST_DIR="/usr/lib/$TRIPLET/cmake/Qt6LinguistTools"

echo "=== configure ==="
cmake -S "$SRC_DIR" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$DIST_DIR" \
    -DCMAKE_PREFIX_PATH="$STAGE_PREFIX" \
    -DQt6Charts_DIR="$CHARTS_DIR" \
    -DQt6LinguistTools_DIR="$LINGUIST_DIR" \
    ${EXTRA_CMAKE_ARGS:-}

echo "=== build ==="
cmake --build "$BUILD_DIR" -j "$JOBS"

echo "=== install -> $DIST_DIR ==="
cmake --install "$BUILD_DIR"

echo "=== verify ==="
"$PORT_ROOT/scripts/90-verify.sh" "$BUILD_DIR" "$STAGE_PREFIX"

echo
echo "Build OK. Run with:"
echo "  LD_LIBRARY_PATH=$STAGE_PREFIX/lib/$TRIPLET QT_QPA_PLATFORM=wayland $DIST_DIR/bin/stacer"
