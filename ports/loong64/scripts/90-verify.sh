#!/usr/bin/env bash
# Post-build verification: ELF arch, dynamic deps, CPU-info probe, GUI startup.
# Usage: scripts/90-verify.sh [build-dir] [stage-prefix]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

BUILD="${1:-$BUILD_DIR}"
STAGE="${2:-$STAGE_USR}"
LIBDIR="$STAGE/lib/$TRIPLET"
BIN="$BUILD/stacer/stacer"
EVIDENCE="$PORT_ROOT/evidence"
mkdir -p "$EVIDENCE"

[[ -x "$BIN" ]] || { echo "ERROR: $BIN not found" >&2; exit 1; }

elf="$(file -b "$BIN")"
echo "[verify] ELF: $elf"
case "$elf" in
    *LoongArch*) arch_result=pass ;;
    *) arch_result=fail ;;
esac

missing="$(LD_LIBRARY_PATH="$LIBDIR" ldd "$BIN" 2>&1 | grep 'not found' || true)"
if [[ -z "$missing" ]]; then
    echo "[verify] dynamic deps: all resolved"
    ldd_result=pass
else
    echo "[verify] dynamic deps MISSING: $missing" >&2
    ldd_result=fail
fi

echo "[verify] hardware-information probe"
"$PORT_ROOT/tests/run.sh" "$SRC_DIR" "$BUILD" "$EVIDENCE/after.json" > /dev/null
probe_result="$(python3 - "$EVIDENCE/after.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
checks = {
    "physicalCoreCount > 0": d["physicalCoreCount"] > 0,
    "clockCount > 0": d["clockCount"] > 0,
    "avgClockMHz > 0": d["avgClockMHz"] > 0,
    "sysCpuSpeed not unknown": "unknown" not in d["sysCpuSpeed"].lower(),
    "platform is loongarch64": "loongarch64" in d["sysPlatform"],
}
for name, ok in checks.items():
    print(("  PASS  " if ok else "  FAIL  ") + name, file=sys.stderr)
print("pass" if all(checks.values()) else "fail")
PY
)"

echo "[verify] GUI startup (offscreen, 5 s)"
gui_log="$(mktemp)"
set +e
env LD_LIBRARY_PATH="$LIBDIR" \
    QT_QPA_PLATFORM=offscreen \
    TMPDIR="$(mktemp -d)" \
    XDG_CONFIG_HOME="$(mktemp -d)" \
    XDG_CACHE_HOME="$(mktemp -d)" \
    XDG_RUNTIME_DIR="$(mktemp -d)" \
    timeout 5 "$BIN" --nosplash > "$gui_log" 2>&1
gui_rc=$?
set -e
if [[ $gui_rc -eq 124 || $gui_rc -eq 0 ]]; then
    echo "[verify] GUI stayed alive (rc=$gui_rc)"
    gui_result=pass
else
    echo "[verify] GUI crashed (rc=$gui_rc):" >&2
    tail -10 "$gui_log" >&2
    gui_result=fail
fi
rm -f "$gui_log"

python3 - "$EVIDENCE/verification.json" "$elf" "$arch_result" "$ldd_result" "$probe_result" "$gui_result" "$gui_rc" <<'PY'
import json, sys
out, elf, arch, ldd, probe, gui, gui_rc = sys.argv[1:]
data = {
    "elf": elf,
    "elfArchLoongArch": arch,
    "dynamicDepsResolved": ldd,
    "cpuInfoProbe": probe,
    "guiStartup": gui,
    "guiExitCode": int(gui_rc),
}
json.dump(data, open(out, "w"), indent=2, ensure_ascii=False)
open(out, "a").write("\n")
PY

echo "[verify] report -> $EVIDENCE/verification.json"
if [[ "$arch_result$ldd_result$probe_result$gui_result" == *fail* ]]; then
    echo "VERIFY FAILED" >&2
    exit 1
fi
echo "VERIFY PASSED"
