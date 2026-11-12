#!/usr/bin/env bash
# Build a loong64 .deb from the installed tree, without root or debhelper.
# Usage: packaging/make-deb.sh [dist-dir]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/common.sh"

DIST="${1:-$DIST_DIR}"
[[ -x "$DIST/bin/stacer" ]] || { echo "ERROR: run ./build.sh first" >&2; exit 1; }

PKG="$PORT_ROOT/.packaging/stacer_${UPSTREAM_VERSION}-3_${TARGET_ARCH}"
DEB="$PORT_ROOT/dist/stacer_${UPSTREAM_VERSION}-3_${TARGET_ARCH}.deb"
rm -rf "$PKG"
mkdir -p "$PKG/DEBIAN" "$PKG/usr"

cp -a "$DIST/bin" "$DIST/share" "$PKG/usr/"

cat > "$PKG/DEBIAN/control" <<EOF
Package: stacer
Version: $UPSTREAM_VERSION-3
Section: utils
Priority: optional
Architecture: $TARGET_ARCH
Maintainer: $PORT_MAINTAINER
Depends: libc6 (>= 2.36), libstdc++6, libgcc-s1, libgl1, libglx0, libopengl0, libxkbcommon0, libvulkan1, libqt6core6 (>= 6.11.0~), libqt6gui6 (>= 6.11.0~), libqt6widgets6 (>= 6.11.0~), libqt6network6 (>= 6.11.0~), libqt6concurrent6 (>= 6.11.0~), libqt6opengl6 (>= 6.11.0~), libqt6svg6 (>= 6.11.0~), libqt6charts6 (>= 6.11.0~), qt6-qpa-plugins
Recommends: qt6-wayland, qt6-gtk-platformtheme
Description: Linux system optimizer and monitoring (LoongArch port)
 Qt6 system monitor and optimizer, ported to loong64. Includes the CPU
 topology/clock fixes, the QtSvg animation compatibility guard, and
 hwmon temperature/GPU monitoring.
 Built against Qt 6.11.2: requires Qt 6.11 or newer at runtime (the ELF
 binary requests the Qt_6.11 symbol version from libQt6Core.so.6).
EOF

mkdir -p "$PORT_ROOT/dist"
dpkg-deb --root-owner-group --build "$PKG" "$DEB" > /dev/null 2>&1 || \
    dpkg-deb --build "$PKG" "$DEB" > /dev/null

echo "[deb] $DEB"
dpkg-deb -I "$DEB" | grep -E 'Package:|Version:|Architecture:|Depends:'
