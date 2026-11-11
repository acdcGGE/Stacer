#!/usr/bin/env bash
# Prepare the two Qt6 dev components missing on Deepin 25 / loong64.
#
# Mode "local" (default, no root needed): apt download + dpkg-deb -x into
# .deps/root, then symlink the l10n executables already shipped by the system
# qt6-l10n-tools package. mode "system" is only used when the machine already
# has both components installed system-wide.
#
# Writes .deps/config.env with STAGE_PREFIX for build.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SYSTEM_CHARTS="/usr/lib/$TRIPLET/cmake/Qt6Charts/Qt6ChartsConfig.cmake"
SYSTEM_LINGUIST="/usr/lib/$TRIPLET/cmake/Qt6LinguistTools/Qt6LinguistToolsConfig.cmake"

mkdir -p "$DEPS_DIR"

if [[ -f "$SYSTEM_CHARTS" && -f "$SYSTEM_LINGUIST" ]]; then
    echo "[deps] Qt6Charts + Qt6LinguistTools are installed system-wide; using /usr."
    printf 'STAGE_PREFIX=/usr\n' > "$DEPS_DIR/config.env"
    exit 0
fi

echo "[deps] system Qt is missing Charts and/or LinguistTools; building a local staging prefix."
echo "[deps] (To install system-wide instead: sudo apt install qt6-charts-dev qt6-tools-dev debhelper)"

mkdir -p "$DEPS_DIR/cache" "$DEPS_DIR/root"
cd "$DEPS_DIR/cache"
for pkg in qt6-charts-dev libqt6charts6 qt6-tools-dev; do
    if ! compgen -G "${pkg}_*.deb" > /dev/null; then
        echo "[deps] apt download $pkg"
        apt download "$pkg" > /dev/null
    fi
done

for deb in *.deb; do
    dpkg-deb -x "$deb" "$DEPS_DIR/root"
done

# Qt6LinguistToolsTargets.cmake references these executables inside the
# staging prefix. They come from qt6-l10n-tools / qt6-tools-dev-tools, which
# are already installed on Deepin 25; just point the imported targets at them.
mkdir -p "$STAGE_USR/lib/qt6/bin" "$STAGE_USR/lib/qt6/libexec"
for tool in lconvert lrelease lupdate; do
    src="/usr/lib/qt6/bin/$tool"
    [[ -x "$src" ]] || { echo "ERROR: $src missing (install qt6-l10n-tools)" >&2; exit 1; }
    ln -sf "$src" "$STAGE_USR/lib/qt6/bin/$tool"
done
for tool in lprodump lrelease-pro lupdate-pro; do
    src="/usr/lib/qt6/libexec/$tool"
    [[ -x "$src" ]] || { echo "ERROR: $src missing (install qt6-tools-dev-tools)" >&2; exit 1; }
    ln -sf "$src" "$STAGE_USR/lib/qt6/libexec/$tool"
done

for cfg in Qt6Charts/Qt6ChartsConfig.cmake Qt6LinguistTools/Qt6LinguistToolsConfig.cmake; do
    [[ -f "$STAGE_USR/lib/$TRIPLET/cmake/$cfg" ]] || {
        echo "ERROR: staging is missing cmake/$cfg" >&2; exit 1; }
done

printf 'STAGE_PREFIX=%s\n' "$STAGE_USR" > "$DEPS_DIR/config.env"
echo "[deps] staging prefix ready: $STAGE_USR"
