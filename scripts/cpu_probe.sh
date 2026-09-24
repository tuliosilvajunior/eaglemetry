#!/usr/bin/env bash
set -euo pipefail

# Records what the app's threads spend on the car, for later study.
#
# The probe is offline on purpose: it writes one log file and reads nothing
# back. What it collects is a pair of per-thread CPU counters, one at the start
# and one at the end, plus periodic samples between them. A delta over a known
# window names the thread that costs, which a single `top` frame cannot: `top`
# reports a share of one instant, and a collector that wakes at 1 Hz is invisible
# in most instants and expensive across a minute.

PACKAGE_NAME="com.timhss.capy"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADB_SERIAL="${ADB_SERIAL:-}"
DURATION=60
INTERVAL=5
OUT_DIR="$ROOT_DIR/dbpull"
LABEL=""

usage() {
    cat <<EOF
Usage: scripts/cpu_probe.sh [options]

Records per-thread CPU counters of $PACKAGE_NAME on the car, into one log file.

Options:
  --duration SECONDS  How long to watch. Default $DURATION.
  --interval SECONDS  Seconds between samples. Default $INTERVAL.
  --label TEXT        Goes in the file name and in the header. Use it to state
                      what the car was doing: "parked", "driving", "charging".
  --device SERIAL     Use a specific adb device, same as adb -s SERIAL.
  --out DIR           Where the log is written. Default dbpull.
  -h, --help          Show this help.

Environment:
  ADB_SERIAL          Default adb serial if --device is not passed.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration) DURATION="${2:?Missing seconds after --duration}"; shift 2 ;;
        --interval) INTERVAL="${2:?Missing seconds after --interval}"; shift 2 ;;
        --label) LABEL="${2:?Missing text after --label}"; shift 2 ;;
        --device) ADB_SERIAL="${2:?Missing serial after --device}"; shift 2 ;;
        --out) OUT_DIR="${2:?Missing directory after --out}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '==> %s\n' "$*" >&2; }

adb_cmd() {
    if [[ -n "$ADB_SERIAL" ]]; then adb -s "$ADB_SERIAL" "$@"; else adb "$@"; fi
}

select_device() {
    command -v adb >/dev/null || die "adb not found in PATH"
    if [[ -n "$ADB_SERIAL" ]]; then
        adb_cmd get-state >/dev/null || die "Device $ADB_SERIAL is not available"
        return
    fi
    local devices count
    devices="$(adb devices | awk 'NR > 1 && $2 == "device" { print $1 }')"
    count="$(printf '%s\n' "$devices" | sed '/^$/d' | wc -l | tr -d ' ')"
    [[ "$count" -eq 1 ]] || { adb devices -l; die "Connect exactly one device, or pass --device SERIAL"; }
    ADB_SERIAL="$devices"
}

select_device
log "Using adb device $ADB_SERIAL"

PID="$(adb_cmd shell "pidof $PACKAGE_NAME" | tr -d '\r' | awk '{print $1}')"
[[ -n "$PID" ]] || die "$PACKAGE_NAME is not running. Open the app first."

mkdir -p "$OUT_DIR"
STAMP="$(date +%Y-%m-%d_%H%M%S)"
SUFFIX="${LABEL:+_${LABEL// /-}}"
OUT_FILE="$OUT_DIR/cpu_probe_${STAMP}${SUFFIX}.log"

# One command per section, so a section that fails leaves the rest readable.
section() {
    printf '\n===== %s =====\n' "$1" >> "$OUT_FILE"
}

# The counters. Field 14 and 15 of /proc/<tid>/stat are user and system jiffies;
# the thread name is in /proc/<tid>/comm, because the name inside stat is
# truncated to 15 characters and several of ours collide there.
thread_counters() {
    # Fields 14 and 15 of /proc/<tid>/stat are the user and system jiffies. The
    # name inside stat is cut at 15 characters and several of ours collide
    # there, so the name is read from /proc/<tid>/comm instead.
    #
    # awk does the field picking. A shell `set --` would need ${14}, and the
    # positional form $14 means "$1 followed by 4" in a POSIX shell, which
    # reports the wrong column without failing.
    adb_cmd shell "
        for t in /proc/$PID/task/*; do
            tid=\${t##*/}
            name=\$(cat \$t/comm 2>/dev/null)
            line=\$(cat \$t/stat 2>/dev/null) || continue
            echo \"\$line\" | awk -v tid=\$tid -v name=\"\$name\" '{ print tid, \$14, \$15, name }'
        done
    " 2>/dev/null | tr -d '\r'
}

{
    echo "# Capy Energy CPU probe"
    echo "package: $PACKAGE_NAME"
    echo "pid: $PID"
    echo "label: ${LABEL:-none}"
    echo "started: $(date -Iseconds)"
    echo "duration_s: $DURATION"
    echo "interval_s: $INTERVAL"
    echo "device: $ADB_SERIAL"
} > "$OUT_FILE"

section "device facts"
{
    adb_cmd shell "getprop ro.build.version.release; getprop ro.product.model; cat /proc/cpuinfo | grep -c ^processor; getprop dalvik.vm.heapsize"
    echo "clock ticks per second:"
    adb_cmd shell "getconf CLK_TCK"
} >> "$OUT_FILE" 2>&1 || true

section "app state before"
{
    adb_cmd shell "dumpsys activity services $PACKAGE_NAME | head -60"
} >> "$OUT_FILE" 2>&1 || true

section "thread counters t0"
thread_counters >> "$OUT_FILE"
T0_EPOCH="$(date +%s)"

log "Watching for ${DURATION}s"
elapsed=0
while [[ "$elapsed" -lt "$DURATION" ]]; do
    section "sample at +${elapsed}s"
    # `top` states who is busy right now, which the deltas cannot: a thread that
    # burns one whole second and sleeps for nine has the same delta as one that
    # runs at ten per cent throughout.
    adb_cmd shell "top -H -b -n 1 -p $PID 2>/dev/null | head -40" >> "$OUT_FILE" 2>&1 || true
    sleep "$INTERVAL"
    elapsed=$((elapsed + INTERVAL))
done

section "thread counters t1"
thread_counters >> "$OUT_FILE"
T1_EPOCH="$(date +%s)"

section "window"
echo "wall_seconds: $((T1_EPOCH - T0_EPOCH))" >> "$OUT_FILE"

section "app state after"
{
    adb_cmd shell "dumpsys gfxinfo $PACKAGE_NAME 2>/dev/null | head -40"
    adb_cmd shell "dumpsys meminfo $PACKAGE_NAME 2>/dev/null | head -30"
} >> "$OUT_FILE" 2>&1 || true

section "recent app log"
# The tail states what ran during the window, so a costly thread can be matched
# with what it was doing.
adb_cmd shell "logcat -d -t 400 --pid=$PID" >> "$OUT_FILE" 2>&1 || true

log "Wrote $OUT_FILE"
echo "$OUT_FILE"
