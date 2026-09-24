#!/usr/bin/env bash
# Test build with the CLOUD_SYNC_ENABLED gate ON for both apps.
#
# Production default is ON on both sides (standing owner decision: the cloud
# stays on). A normal build therefore already moves telemetry to the cloud
# once Supabase credentials are configured. This script makes the
# test path foolproof: it refuses to build when any local config
# contradicts the gate, then builds both apps with the gate on.
#
# Usage: scripts/build_cloud_sync_test.sh [check|car|companion|all]
#   check      verify local config only, build nothing
#   car        check + build the car APK (scripts/install.sh --build-only)
#   companion  check + build the companion APK
#   all        check + build both (default)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
MODE="${1:-all}"

die() { echo "build_cloud_sync_test: $*" >&2; exit 1; }

# Fail when a gitignored local file pins the gate OFF: gradle reads
# local.properties first, so an env export would NOT override it, and a
# stale CLOUD_SYNC_ENABLED=false in .env would fight the explicit
# --dart-define below. Absent file = fine (falls through to our explicit on).
assert_gate_not_off() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    if grep -Eq '^[[:space:]]*CLOUD_SYNC_ENABLED[[:space:]]*=[[:space:]]*false' "$file"; then
        die "$file pins CLOUD_SYNC_ENABLED=false — set it to true or delete the line, then rerun"
    fi
}

require_env() {
    [[ -f "$1" ]] || die "missing $1 — copy the matching .example file and fill it in"
}

check() {
    # usage: check {all|car|companion}
    assert_gate_not_off "$ROOT_DIR/android/local.properties"
    assert_gate_not_off "$ROOT_DIR/.env"
    assert_gate_not_off "$ROOT_DIR/apps/companion/.env"
    case "${1:-all}" in
        car) require_env "$ROOT_DIR/.env" ;;
        companion) require_env "$ROOT_DIR/apps/companion/.env" ;;
        *) require_env "$ROOT_DIR/.env"; require_env "$ROOT_DIR/apps/companion/.env" ;;
    esac
    echo "gate check OK: nothing pins CLOUD_SYNC_ENABLED=false"
}

build_car() {
    # Gradle precedence: local.properties > gradle property > env.
    # check() already ruled out a contradicting local.properties, so the
    # env export below reliably turns the native BuildConfig gate on.
    CLOUD_SYNC_ENABLED=true "$ROOT_DIR/scripts/install.sh" --build-only
}

build_companion() {
    # Explicit --dart-define wins over --dart-define-from-file, so the gate
    # is on even when the .env template line is still commented out.
    (cd "$ROOT_DIR/apps/companion" && "$FLUTTER_BIN" build apk --release \
        --dart-define-from-file=.env \
        --dart-define=CLOUD_SYNC_ENABLED=true)
}

case "$MODE" in
    check) check all ;;
    car) check car; build_car ;;
    companion) check companion; build_companion ;;
    all) check all; build_car; build_companion ;;
    *) die "unknown mode '$MODE' — use check|car|companion|all" ;;
esac
