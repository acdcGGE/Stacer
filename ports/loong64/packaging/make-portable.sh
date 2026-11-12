#!/usr/bin/env bash
# Build a distribution-agnostic tarball (same CPU architecture, any Linux
# distro with Qt6 installed). No root, no packaging tool required.
#
#   packaging/make-portable.sh                 # plain binary + launcher
#   packaging/make-portable.sh --bundle-charts  # also ship libQt6Charts.so.6
#
# NOTE: this is cross-DISTRO, not cross-ARCH. The binary is loongarch64;
# on x86_64 / aarch64 use packaging/archlinux/PKGBUILD to build from source.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/common.sh"

DIST="$DIST_DIR"
BUNDLE=0
case "${1:-}" in
    --bundle-charts) BUNDLE=1 ;;
    "") ;;
    *) DIST="$1" ;;
esac
if [[ "${2:-}" == "--bundle-charts" ]]; then BUNDLE=1; fi

[[ -x "$DIST/bin/stacer" ]] || { echo "ERROR: run ./build.sh first" >&2; exit 1; }

# Derive runtime requirements from the actual ELF so the docs match whichever
# Qt/glibc the build host had (Deepin 6.8, sid 6.11, Arch 6.12, ...).
bin_verdump="$(LC_ALL=C readelf -V "$DIST/bin/stacer")"
QT_NEED_NODE="$(printf '%s\n' "$bin_verdump" | awk '
    /File: libQt6Core\.so\.6/ {f=1; next} /File: / {f=0} f' \
    | grep -o 'Qt_6\.[0-9][0-9]*' | sed 's/Qt_6\.//' | sort -n | tail -1)"
[[ -n "$QT_NEED_NODE" ]] || { echo "ERROR: cannot derive Qt symbol version from binary" >&2; exit 1; }
QT_NEED="6.$QT_NEED_NODE"
GLIBC_NEED="$(printf '%s\n' "$bin_verdump" | awk '
    /File: libc\.so\.6/ {f=1; next} /File: / {f=0} f' \
    | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/GLIBC_//' | sort -V | tail -1)"
if (( QT_NEED_NODE >= 9 )); then
    ANIM_NOTE="Animation note: this binary was COMPILED against Qt $QT_NEED (>= 6.9),
so the loader SVGs keep the upstream 60 fps animation."
else
    ANIM_NOTE="Animation note: this binary was COMPILED against Qt $QT_NEED, so the loader
SVGs are rendered as static frames (workaround for a QtSvg heap-corruption
crash on loong64). That choice is made at build time: installing this binary
on a Qt >= 6.9 system does NOT restore the 60 fps animation. Rebuild from
source on that system (./build.sh or the PKGBUILD) to get animation back."
fi

NAME="stacer-${UPSTREAM_VERSION}-${TARGET_ARCH}-linux-portable"
if (( BUNDLE )); then NAME="${NAME}-bundled"; fi
WORK="$PORT_ROOT/.packaging/$NAME"
TARBALL="$PORT_ROOT/dist/$NAME.tar.gz"
rm -rf "$WORK"
mkdir -p "$WORK/usr" "$PORT_ROOT/dist"
cp -a "$DIST/bin" "$DIST/share" "$WORK/usr/"

if (( BUNDLE )); then
    CHARTS_LIB="$STAGE_USR/lib/$TRIPLET/libQt6Charts.so.6"
    [[ -f "$CHARTS_LIB" ]] || { echo "ERROR: $CHARTS_LIB not found" >&2; exit 1; }
    mkdir -p "$WORK/lib"
    cp -L "$CHARTS_LIB" "$WORK/lib/"
    echo "[portable] bundled libQt6Charts.so.6 (same-architecture only)"
fi

cat > "$WORK/stacer-run.sh" <<'LAUNCHER'
#!/usr/bin/env bash
# Locate a matching Qt6Charts at runtime and start Stacer.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Prefer the SYSTEM Qt6Charts. Mixing a bundled Charts from one Qt minor
# into a system with another risks private-ABI mismatch (Qt Charts uses
# QtGui private API). The bundled copy is only a fallback for machines
# without qt6-charts.
libdir=""
system_charts=""
for d in \
    /usr/lib/loongarch64-linux-gnu \
    /usr/lib/x86_64-linux-gnu \
    /usr/lib/aarch64-linux-gnu \
    /usr/lib64 /usr/lib /usr/local/lib; do
    if [[ -f "$d/libQt6Charts.so.6" ]]; then system_charts="$d"; break; fi
done

if [[ "${STACER_FORCE_BUNDLED_LIBS:-0}" == "1" && -f "$HERE/lib/libQt6Charts.so.6" ]]; then
    libdir="$HERE/lib"
elif [[ -n "$system_charts" ]]; then
    libdir="$system_charts"
elif [[ -f "$HERE/lib/libQt6Charts.so.6" ]]; then
    libdir="$HERE/lib"
    echo "note: using bundled libQt6Charts; it must match your system Qt minor." >&2
    echo "      If versions differ, install the distro qt6-charts package instead." >&2
fi

if [[ -n "$libdir" ]]; then
    export LD_LIBRARY_PATH="$libdir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
elif [[ -z "${STACER_SKIP_DEP_WARN:-}" ]]; then
    echo "warning: libQt6Charts.so.6 not found in common paths." >&2
    echo "         install your distro's Qt6 Charts package, e.g." >&2
    echo "         Debian/Deepin: qt6-charts-dev   Arch: qt6-charts   Fedora: qt6-qtcharts" >&2
fi

if [[ -z "${QT_QPA_PLATFORM:-}" ]]; then
    if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then export QT_QPA_PLATFORM=wayland
    elif [[ -n "${DISPLAY:-}" ]]; then export QT_QPA_PLATFORM=xcb
    fi
fi

exec "$HERE/usr/bin/stacer" "$@"
LAUNCHER
chmod +x "$WORK/stacer-run.sh"
cp "$PORT_ROOT/scripts/check-target-compat.sh" "$WORK/check-target-compat.sh"
chmod +x "$WORK/check-target-compat.sh"

cat > "$WORK/README-portable.txt" <<EOF
Stacer $UPSTREAM_VERSION - portable build ($TARGET_ARCH / $(uname -m))
Built from upstream $UPSTREAM_COMMIT with this repository's patches.

Run:
  ./stacer-run.sh
  ./stacer-run.sh --nosplash

Minimum runtime requirements (any Linux of the SAME CPU architecture):
  - Qt $QT_NEED OR NEWER. This binary requests the ELF symbol version Qt_$QT_NEED
    from libQt6Core.so.6; older Qt will fail with
    "version Qt_$QT_NEED not found". All Qt modules must be the same version.
  - Qt6 Base (Core/Gui/Widgets/Network/Concurrent/OpenGL), Qt6 Charts, Qt6 Svg
  - Qt6 platform plugin for your session (xcb / wayland)
  - glibc >= $GLIBC_NEED, libGL, libxkbcommon
  Debian/Deepin : apt install libqt6charts6 qt6-qpa-plugins qt6-wayland
  Arch          : pacman -S qt6-base qt6-charts qt6-svg qt6-wayland
  Fedora        : dnf install qt6-qtcharts qt6-qtbase-gui

Check first: ./check-target-compat.sh (included, no root needed; --json
emits machine-readable results). It verifies Qt >= $QT_NEED, glibc >= $GLIBC_NEED,
shared libraries and QPA plugins before you even unpack/install.

This tarball is cross-DISTRO, NOT cross-ARCH: the binary is $(uname -m).
For x86_64 / aarch64, build from source with packaging/archlinux/PKGBUILD
(or ./build.sh on that machine).

$ANIM_NOTE

Bundled variant (-bundled): stacer-run.sh prefers the system libQt6Charts
and falls back to the bundled Qt $QT_NEED copy only when none is installed.
Set STACER_FORCE_BUNDLED_LIBS=1 to force the bundled library.
EOF

tar -C "$PORT_ROOT/.packaging" -czf "$TARBALL" "$NAME"
# Emit a bare filename so `sha256sum -c` works after downloading the asset;
# using $TARBALL directly would bake this machine's absolute path into it.
(
    cd "$(dirname "$TARBALL")"
    sha256sum "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256"
)
echo "[portable] $TARBALL"
echo "[portable] $(du -h "$TARBALL" | cut -f1), sha256 in $TARBALL.sha256"
