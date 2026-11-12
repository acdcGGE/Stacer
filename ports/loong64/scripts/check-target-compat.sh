#!/usr/bin/env bash
# Standalone runtime compatibility probe for the Stacer loong64 port.
#
# Copy this ONE file to the target machine and run it before installing the
# .deb or unpacking the portable tarball. No root, no repository, no build
# toolchain required. It answers the question "will this binary run HERE?".
#
# Usage:
#   ./check-target-compat.sh [path/to/stacer] [--json]
#
# Exit status: 0 = compatible, 1 = incompatible, 2 = usage/IO error.
#
# What it checks (all derived from the actual built ELF, not guesses):
#   - CPU architecture is loongarch64 / dpkg loong64
#   - libQt6Core.so.6 exports the Qt_6.x ELF symbol version the binary
#     requires (read from its .gnu.version_r; 6.8 for a Deepin build,
#     6.11 for a Debian sid build, ...)
#   - glibc >= the highest GLIBC_* symbol requested by the binary
#   - every DT_NEEDED library resolves (ldd)
#   - Qt6 platform plugins are present
#   - Qt6 modules are not mixed across minor versions
set -uo pipefail
# readelf section labels are localized; parsing below expects English.
export LC_ALL=C

PROG="$(basename "$0")"
BIN=""
AS_JSON=0

for arg in "$@"; do
    case "$arg" in
        --json) AS_JSON=1 ;;
        -h|--help)
            printf 'Usage: %s [path/to/stacer] [--json]\n' "$PROG"
            exit 0 ;;
        *) BIN="$arg" ;;
    esac
done

if [[ -z "$BIN" ]]; then
    for candidate in /usr/bin/stacer ./usr/bin/stacer ./dist/bin/stacer ./stacer; do
        if [[ -x "$candidate" ]]; then BIN="$candidate"; break; fi
    done
fi
if [[ -n "$BIN" && ! -r "$BIN" ]]; then
    printf 'ERROR: cannot read binary: %s\n' "$BIN" >&2
    exit 2
fi

CHECKS_JSON=()
HUMAN=()
WARNINGS=()
FAILED=0

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/ }"
    s="${s//$'\t'/ }"
    printf '%s' "$s"
}

record() {
    # record <name> <ok:true|false> <detail>
    local name="$1" ok="$2" detail="$3"
    CHECKS_JSON+=("{\"name\":\"$(json_escape "$name")\",\"ok\":$ok,\"detail\":\"$(json_escape "$detail")\"}")
    if [[ "$ok" == "true" ]]; then
        HUMAN+=("[ OK ] $name: $detail")
    else
        HUMAN+=("[FAIL] $name: $detail")
        FAILED=$((FAILED + 1))
    fi
}

warn() {
    # warn <name> <detail>
    local name="$1" detail="$2"
    WARNINGS+=("$name: $detail")
    HUMAN+=("[WARN] $name: $detail")
}

json_string_array() {
    local out="" x
    for x in "$@"; do
        [[ -z "$x" ]] && continue
        out+="\"$(json_escape "$x")\","
    done
    printf '%s' "${out%,}"
}

# ---- helpers -------------------------------------------------------------
find_lib() {
    # find_lib <soname>
    local soname="$1" p
    p="$(ldconfig -p 2>/dev/null | awk -v s="$soname" '$1 == s {print $NF; exit}')"
    if [[ -z "$p" ]]; then
        for d in \
            /usr/lib/loongarch64-linux-gnu /usr/lib/x86_64-linux-gnu \
            /usr/lib/aarch64-linux-gnu /usr/lib64 /usr/lib /usr/local/lib; do
            if [[ -f "$d/$soname" ]]; then p="$d/$soname"; break; fi
        done
    fi
    [[ -n "$p" && -r "$p" ]] && printf '%s' "$p"
}

qt_max_node() {
    # Highest Qt_6.x version definition in a Qt library. Returns e.g. "8".
    local lib="$1"
    [[ -r "$lib" ]] || return 0
    readelf -V "$lib" 2>/dev/null \
        | grep -o 'Qt_6\.[0-9][0-9]*' \
        | sed 's/Qt_6\.//' \
        | sort -n | tail -1
}

version_ge() {
    # version_ge <have> <need>, dpkg preferred, sort -V as fallback
    local have="$1" need="$2"
    if command -v dpkg >/dev/null 2>&1; then
        dpkg --compare-versions "$have" ge "$need" 2>/dev/null && return 0
    fi
    [[ "$(printf '%s\n%s\n' "$need" "$have" | sort -V | head -1)" == "$need" ]]
}

# ---- 1. architecture -----------------------------------------------------
machine="$(uname -m 2>/dev/null || echo unknown)"
dpkg_arch=""
command -v dpkg >/dev/null 2>&1 && dpkg_arch="$(dpkg --print-architecture 2>/dev/null || true)"
if [[ "$machine" == "loongarch64" || "$dpkg_arch" == "loong64" ]]; then
    record "architecture" "true" "uname=$machine dpkg=${dpkg_arch:-n/a}; matches LoongArch64"
else
    record "architecture" "false" "uname=$machine dpkg=${dpkg_arch:-n/a}; this binary is loongarch64 only (rebuild from source)"
fi

# ---- 2. Qt Core symbol version ------------------------------------------
# The requirement comes from the binary itself, not a hardcoded minor.
QT_NEED_NODE=""
if [[ -n "$BIN" ]] && command -v readelf >/dev/null 2>&1; then
    QT_NEED_NODE="$(readelf -V "$BIN" 2>/dev/null | awk '
        /File: libQt6Core\.so\.6/ {incore=1; next}
        /File: / {incore=0}
        incore' | grep -o 'Qt_6\.[0-9][0-9]*' | sed 's/Qt_6\.//' | sort -n | tail -1)"
fi
CORE_LIB="$(find_lib libQt6Core.so.6)"
QT_MAJOR_NODE=""
if [[ -z "$CORE_LIB" ]]; then
    record "qt_core" "false" "libQt6Core.so.6 not found; install Qt6 Base"
elif ! command -v readelf >/dev/null 2>&1; then
    warn "qt_core" "readelf unavailable, cannot verify Qt symbol version (install binutils)"
else
    QT_MAJOR_NODE="$(qt_max_node "$CORE_LIB")"
    # Keep the dump in a variable: `cmd | grep -q` makes grep exit early and
    # triggers SIGPIPE under `set -o pipefail`, which would look like a failure.
    core_verdump="$(readelf -V "$CORE_LIB" 2>/dev/null || true)"
    if [[ -z "$QT_NEED_NODE" ]]; then
        warn "qt_core" "no binary given to derive the required Qt node; environment highest is Qt_6.${QT_MAJOR_NODE:-?}"
    elif [[ "$core_verdump" == *"Qt_6.$QT_NEED_NODE"* ]]; then
        record "qt_core" "true" "$CORE_LIB provides Qt_6.$QT_NEED_NODE (highest node Qt_6.${QT_MAJOR_NODE:-?}); binary needs Qt >= 6.$QT_NEED_NODE"
    else
        record "qt_core" "false" "$CORE_LIB does NOT provide Qt_6.$QT_NEED_NODE (highest node Qt_6.${QT_MAJOR_NODE:-?}); runtime would fail with 'version Qt_6.$QT_NEED_NODE not found'"
    fi
fi

# ---- 3. glibc ------------------------------------------------------------
GLIBC_NEED="2.36"
if [[ -n "$BIN" ]] && command -v readelf >/dev/null 2>&1; then
    glibc_derived="$(readelf -V "$BIN" 2>/dev/null | awk '
        /File: libc\.so\.6/ {f=1; next}
        /File: / {f=0}
        f' | grep -o 'GLIBC_[0-9][0-9.]*' | sort -V | tail -1)"
    [[ -n "$glibc_derived" ]] && GLIBC_NEED="${glibc_derived#GLIBC_}"
fi
libc_ver=""
if command -v ldd >/dev/null 2>&1; then
    libc_ver="$(ldd --version 2>/dev/null | head -1 | grep -o -E '[0-9]+\.[0-9]+$' | head -1)"
fi
if [[ -z "$libc_ver" ]]; then
    warn "glibc" "cannot determine glibc version; binary needs >= $GLIBC_NEED"
elif version_ge "$libc_ver" "$GLIBC_NEED"; then
    record "glibc" "true" "$libc_ver >= $GLIBC_NEED (highest GLIBC_* symbol used)"
else
    record "glibc" "false" "$libc_ver < $GLIBC_NEED; binary would fail with 'GLIBC_$GLIBC_NEED not found'"
fi

# ---- 4. DT_NEEDED resolution --------------------------------------------
if [[ -n "$BIN" ]]; then
    elf_header="$(readelf -h "$BIN" 2>/dev/null || true)"
    if command -v readelf >/dev/null 2>&1 && \
       [[ "${elf_header,,}" == *loongarch* ]]; then
        record "elf_machine" "true" "$BIN is a LoongArch ELF"
    elif command -v readelf >/dev/null 2>&1; then
        record "elf_machine" "false" "$BIN is not a LoongArch ELF"
    fi

    missing=""
    if command -v ldd >/dev/null 2>&1; then
        missing="$(ldd "$BIN" 2>/dev/null | grep 'not found' | sed 's/^[[:space:]]*//' | paste -sd'; ' - || true)"
    fi
    if [[ -n "$missing" ]]; then
        record "shared_libs" "false" "unresolved: $missing"
    elif command -v ldd >/dev/null 2>&1; then
        record "shared_libs" "true" "all DT_NEEDED libraries resolve"
    else
        warn "shared_libs" "ldd unavailable, skipped"
    fi
else
    warn "binary" "no stacer binary given/found; skipped ldd and ELF checks (environment-only probe)"
fi

# ---- 5. QPA platform plugins --------------------------------------------
plug_dirs=(
    /usr/lib/loongarch64-linux-gnu/qt6/plugins/platforms
    /usr/lib/x86_64-linux-gnu/qt6/plugins/platforms
    /usr/lib/aarch64-linux-gnu/qt6/plugins/platforms
    /usr/lib64/qt6/plugins/platforms
    /usr/lib/qt6/plugins/platforms
)
qpa_found=""
for d in "${plug_dirs[@]}"; do
    if compgen -G "$d/libq*.so" >/dev/null 2>&1; then qpa_found="$d"; break; fi
done
if [[ -n "$qpa_found" ]]; then
    n="$(find "$qpa_found" -maxdepth 1 -name 'libq*.so' | wc -l | tr -d ' ')"
    record "qpa_plugins" "true" "$qpa_found ($n plugins)"
else
    record "qpa_plugins" "false" "no Qt6 platform plugins found; GUI cannot start (install qt6-qpa-plugins / qt6-wayland)"
fi

# ---- 6. Qt module version consistency -----------------------------------
if [[ -n "${QT_MAJOR_NODE:-}" ]] && command -v readelf >/dev/null 2>&1; then
    mixed=""
    seen="Qt_6.$QT_MAJOR_NODE (Core)"
    for soname in libQt6Gui.so.6 libQt6Svg.so.6 libQt6Charts.so.6 libQt6Widgets.so.6; do
        lib="$(find_lib "$soname")"
        [[ -z "$lib" ]] && continue
        node="$(qt_max_node "$lib")"
        [[ -z "$node" ]] && continue
        seen="$seen, Qt_6.$node (${soname%%.so.*})"
        if [[ "$node" != "$QT_MAJOR_NODE" ]]; then mixed="$mixed ${soname%%.so.*}=Qt_6.$node"; fi
    done
    if [[ -n "$mixed" ]]; then
        warn "qt_module_consistency" "mixed minor versions:$mixed (Core=Qt_6.$QT_MAJOR_NODE). Qt Charts uses QtGui private API; mixing can crash"
    else
        record "qt_module_consistency" "true" "$seen"
    fi
fi

# ---- verdict -------------------------------------------------------------
if (( FAILED == 0 )); then
    compatible="true"
    verdict="Compatible: Qt >= 6.${QT_NEED_NODE:-?}, glibc >= $GLIBC_NEED, all shared libraries resolve."
else
    compatible="false"
    verdict="Incompatible: $FAILED check(s) failed. Do not install this binary here; rebuild from source on this system."
fi

if (( AS_JSON )); then
    printf '{\n'
    printf '  "binary": "%s",\n' "$(json_escape "${BIN:-}")"
    printf '  "machine": "%s",\n' "$(json_escape "$machine")"
    printf '  "dpkgArchitecture": "%s",\n' "$(json_escape "$dpkg_arch")"
    printf '  "qtCoreLibrary": "%s",\n' "$(json_escape "${CORE_LIB:-}")"
    printf '  "qtRequiredNode": "Qt_6.%s",\n' "$(json_escape "${QT_NEED_NODE:-}")"
    printf '  "qtHighestNode": "Qt_6.%s",\n' "$(json_escape "${QT_MAJOR_NODE:-}")"
    printf '  "glibc": "%s",\n' "$(json_escape "$libc_ver")"
    printf '  "glibcRequired": "%s",\n' "$(json_escape "$GLIBC_NEED")"
    printf '  "warnings": [%s],\n' "$(json_string_array "${WARNINGS[@]:-}")"
    printf '  "checks": [%s],\n' "$(IFS=,; printf '%s' "${CHECKS_JSON[*]:-}")"
    printf '  "compatible": %s,\n' "$compatible"
    printf '  "verdict": "%s"\n' "$(json_escape "$verdict")"
    printf '}\n'
else
    printf 'Stacer loong64 runtime compatibility probe\n'
    printf 'binary: %s\n\n' "${BIN:-(environment only)}"
    for line in "${HUMAN[@]}"; do printf '%s\n' "$line"; done
    printf '\n%s\n' "$verdict"
fi

(( FAILED == 0 )) && exit 0 || exit 1
