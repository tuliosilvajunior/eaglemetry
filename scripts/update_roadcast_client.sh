#!/usr/bin/env bash
set -euo pipefail

# Copies the Roadcast Android binaries into this repository's build tree.
#
# This repository does NOT distribute the Roadcast binaries on purpose.
# They are local-only build inputs, ignored by .gitignore, built from the
# separate public Roadcast project under Apache 2.0:
#   https://github.com/Timoteohss/roadcast
#
# Build both binaries from that source first (see the README's Roadcast
# section), then run this script with the two build outputs. The checkout
# may be a fresh public clone; nothing here depends on any machine-local
# path.
#
# Usage:
#   scripts/update_roadcast_client.sh <libroadcast_client.so> <roadcastd>
#   scripts/update_roadcast_client.sh --roadcast-root <checkout> [--api 28]
#
# With --roadcast-root the script takes the default build outputs for the
# arm64 API level under that checkout.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROADCAST_URL="https://github.com/Timoteohss/roadcast"
API=28
ROADCAST_ROOT=""
CLIENT_SOURCE=""
DAEMON_SOURCE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --roadcast-root) ROADCAST_ROOT="${2:?Missing path after --roadcast-root}"; shift 2 ;;
    --api) API="${2:?Missing API level after --api}"; shift 2 ;;
    -h|--help)
      sed -n '3,18p' "$0" | sed 's/^# //; s/^#$//'
      exit 0
      ;;
    *)
      if [[ -z "$CLIENT_SOURCE" ]]; then
        CLIENT_SOURCE="$1"
      elif [[ -z "$DAEMON_SOURCE" ]]; then
        DAEMON_SOURCE="$1"
      else
        echo "Unexpected argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -n "$ROADCAST_ROOT" ]]; then
  BUILD_DIR="$ROADCAST_ROOT/build/android-arm64-v8a-api$API"
  CLIENT_SOURCE="${CLIENT_SOURCE:-"$BUILD_DIR/libroadcast_client.so"}"
  DAEMON_SOURCE="${DAEMON_SOURCE:-"$BUILD_DIR/roadcastd"}"
fi

if [[ -z "$CLIENT_SOURCE" || -z "$DAEMON_SOURCE" ]]; then
  echo "Usage: scripts/update_roadcast_client.sh <libroadcast_client.so> <roadcastd>" >&2
  echo "   or: scripts/update_roadcast_client.sh --roadcast-root <checkout>" >&2
  echo "Build both binaries from $ROADCAST_URL first." >&2
  exit 1
fi

CLIENT_DESTINATION="$ROOT/android/app/src/main/jniLibs/arm64-v8a"
DAEMON_DESTINATION="$ROOT/android/app/src/main/assets"

if [ ! -f "$CLIENT_SOURCE" ]; then
  echo "Roadcast Android client not found: $CLIENT_SOURCE" >&2
  echo "Build it in the Roadcast repository before updating the app." >&2
  exit 1
fi
if [ ! -f "$DAEMON_SOURCE" ]; then
  echo "Roadcast Android daemon not found: $DAEMON_SOURCE" >&2
  echo "Build it in the Roadcast repository before updating the app." >&2
  exit 1
fi

mkdir -p "$CLIENT_DESTINATION" "$DAEMON_DESTINATION"
install -m 0755 "$CLIENT_SOURCE" "$CLIENT_DESTINATION/libroadcast_client.so"
install -m 0755 "$DAEMON_SOURCE" "$DAEMON_DESTINATION/roadcastd"

CLIENT_CHECKSUM="$(shasum -a 256 "$CLIENT_DESTINATION/libroadcast_client.so" | awk '{print $1}')"
DAEMON_CHECKSUM="$(shasum -a 256 "$DAEMON_DESTINATION/roadcastd" | awk '{print $1}')"

echo "Installed Roadcast Android binaries (local-only, gitignored)"
echo "  client: $CLIENT_DESTINATION/libroadcast_client.so"
echo "    sha256: $CLIENT_CHECKSUM"
echo "  daemon: $DAEMON_DESTINATION/roadcastd"
echo "    sha256: $DAEMON_CHECKSUM"
