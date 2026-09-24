#!/usr/bin/env bash
set -euo pipefail

PACKAGE_NAME="com.timhss.capy"

# Keep in step with AppUpdateManager.LOCAL_BUILD_SUFFIX. A version name that
# ends in this tells the running app it is a working-tree build, and the
# update watchdog leaves it alone.
LOCAL_BUILD_SUFFIX="-debug"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APK_PATH="$ROOT_DIR/build/app/outputs/flutter-apk/app-release.apk"
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
ADB_SERIAL="${ADB_SERIAL:-}"

DO_BUILD=1
BUILD_ONLY=0

usage() {
    cat <<EOF
Usage: scripts/install.sh [options]

Builds and installs Capy Energy as an ordinary app in /data/app.

The car permissions the app declares are 'signature|privileged'. The release
build is signed with the platform key, which satisfies the signature branch on
its own, so nothing has to live in /system: no priv-app APK, no permission
whitelist XML, no remount, no reboot. This is the only supported install path.

The version name is stamped with '$LOCAL_BUILD_SUFFIX'. The app reads that mark and
switches its update watchdog off, so a build installed here is not replaced
by the published release a minute after it starts.

Supabase: copy .env.example to .env and fill in SUPABASE_URL. The build
reads it via --dart-define-from-file=.env (String.fromEnvironment). Leave
SUPABASE_URL empty in .env and the app runs with no account at all: pairing,
sync and history are unchanged. They never needed a server. If .env is
missing and SUPABASE_URL is not otherwise supplied (e.g. SUPABASE_URL env),
the build fails rather than embedding the placeholder https://example.supabase.co.

Options:
  --device SERIAL   Use a specific adb device, same as adb -s SERIAL.
  --no-build        Install the existing release APK without rebuilding.
  --build-only      Build the release APK and stop. No device is needed, and
                    adb is never called, so this runs with the car switched
                    off.
  -h, --help        Show this help.

Environment:
  ADB_SERIAL        Default adb serial if --device is not passed.
  FLUTTER_BIN       Flutter executable. Defaults to 'flutter' on PATH.
  SUPABASE_URL      Alternative to .env for the Supabase URL (compile-time
                    dart-define). When .env is absent this must be set, or
                    the script aborts.

EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)
            ADB_SERIAL="${2:?Missing serial after --device}"
            shift 2
            ;;
        --no-build)
            DO_BUILD=0
            shift
            ;;
        --build-only)
            BUILD_ONLY=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 2
            ;;
    esac
done

log() {
    printf '\n==> %s\n' "$*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

adb_cmd() {
    if [[ -n "$ADB_SERIAL" ]]; then
        adb -s "$ADB_SERIAL" "$@"
    else
        adb "$@"
    fi
}

require_file() {
    [[ -f "$1" ]] || die "Missing required file: $1"
}

select_device() {
    command -v adb >/dev/null || die "adb not found in PATH"

    if [[ -n "$ADB_SERIAL" ]]; then
        log "Using adb device $ADB_SERIAL"
        adb_cmd get-state >/dev/null || die "Device $ADB_SERIAL is not available"
        return
    fi

    local devices
    devices="$(adb devices | awk 'NR > 1 && $2 == "device" { print $1 }')"
    local count
    count="$(printf '%s\n' "$devices" | sed '/^$/d' | wc -l | tr -d ' ')"

    if [[ "$count" -eq 0 ]]; then
        adb devices -l
        die "No online adb device found"
    fi
    if [[ "$count" -gt 1 ]]; then
        adb devices -l
        die "More than one online adb device found. Pass --device SERIAL or set ADB_SERIAL."
    fi

    ADB_SERIAL="$devices"
    log "Using adb device $ADB_SERIAL"
}

build_release() {
    if [[ "$DO_BUILD" -eq 0 ]]; then
        log "Skipping Flutter build"
        require_file "$APK_PATH"
        return
    fi

    if [[ "$FLUTTER_BIN" == */* ]]; then
        [[ -x "$FLUTTER_BIN" ]] || die "Flutter executable not found: $FLUTTER_BIN"
    else
        command -v "$FLUTTER_BIN" >/dev/null || die "Flutter executable not found: $FLUTTER_BIN (not on PATH)"
    fi
    # A build made here is not on the release channel, so its version code has
    # no relation to the published one and is usually lower. The app's update
    # watchdog compares only those numbers, so without a mark it replaces this
    # build with the published one a minute after it starts — and takes the
    # database with it when the published build is older by schema. The
    # suffix is that mark: AppUpdateManager.LOCAL_BUILD_SUFFIX.
    local version build_name
    version="$(awk -F': *' '/^version:/ { print $2; exit }' "$ROOT_DIR/pubspec.yaml")"
    [[ -n "$version" ]] || die "No version: line in pubspec.yaml"
    build_name="${version%%+*}$LOCAL_BUILD_SUFFIX"

    local dart_define_args=()
    if [[ -f "$ROOT_DIR/.env" ]]; then
        dart_define_args+=(--dart-define-from-file="$ROOT_DIR/.env")
    elif [[ -n "${SUPABASE_URL:-}" ]]; then
        dart_define_args+=(--dart-define=SUPABASE_URL="$SUPABASE_URL")
    else
        die "Missing $ROOT_DIR/.env — copy .env.example to .env and fill in SUPABASE_URL (or leave it empty to run with no account; pairing, sync and history never needed a server). See .env.example. Alternatively, export SUPABASE_URL in the environment."
    fi

    log "Building Flutter release APK ($build_name)"
    (cd "$ROOT_DIR" && "$FLUTTER_BIN" build apk --release \
        --target-platform android-arm64 --build-name "$build_name" "${dart_define_args[@]}")
    require_file "$APK_PATH"
}

install_update() {
    require_file "$APK_PATH"
    log "Installing APK"
    adb_cmd install -r "$APK_PATH"
}

validate_install() {
    log "Validating install path"
    adb_cmd shell "pm path '$PACKAGE_NAME'"

    log "Validating the build is marked local"
    local installed_name
    installed_name="$(adb_cmd shell "dumpsys package '$PACKAGE_NAME' | grep -m1 versionName" \
        | tr -d '\r' | sed 's/.*versionName=//')"
    echo "versionName=$installed_name"
    case "$installed_name" in
        *"$LOCAL_BUILD_SUFFIX")
            ;;
        *)
            die "Installed versionName '$installed_name' does not end in \
'$LOCAL_BUILD_SUFFIX'. The update watchdog will replace this build."
            ;;
    esac

    log "Validating selected car permissions"
    adb_cmd shell "dumpsys package '$PACKAGE_NAME' | grep -E 'android.car.permission.(CAR_PROPERTY|CAR_POWERTRAIN|CAR_SPEED|CAR_ENERGY|CAR_MILEAGE)' | head -40" || true
}

main() {
    if [[ "$BUILD_ONLY" -eq 1 ]]; then
        [[ "$DO_BUILD" -eq 1 ]] || die "--build-only and --no-build ask for opposite things"
        # Deliberately before any adb call: the point of this flag is a build
        # that does not depend on a car being plugged in.
        build_release
        log "Built $APK_PATH"
        log "Done"
        return
    fi

    select_device
    build_release
    install_update
    validate_install
    log "Done"
}

main "$@"
