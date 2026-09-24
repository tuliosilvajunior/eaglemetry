#!/usr/bin/env bash
set -euo pipefail

# Generate the platform keystore from the public AOSP test key.
#
# This is the public AOSP test platform key (alias platform, passwords android),
# not a confidential OEM production key.
# The key pair is committed as platform.pk8 / platform.x509.pem under
# refs/aosp-security/ so any clone can rebuild platform.jks deterministically.
# The resulting JKS certificate SHA-256 is pinned by .github/workflows/release.yml
# as EXPECTED_SIGNING_CERT_SHA256.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$ROOT_DIR/refs/aosp-security"
PK8="$SRC_DIR/platform.pk8"
PEM="$SRC_DIR/platform.x509.pem"
JKS="$SRC_DIR/platform.jks"
EXPECTED_SHA256="c8a2e9bccf597c2fb6dc66bee293fc13f2fc47ec77bc6b2b0d52c11f51192ab8"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "$PK8" ]] || die "Missing source private key: $PK8"
[[ -f "$PEM" ]] || die "Missing source certificate: $PEM"

command -v openssl >/dev/null || die "openssl not found in PATH"
command -v keytool >/dev/null || die "keytool not found in PATH (JDK required)"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

KEY_PEM="$TMPDIR/platform.key.pem"
P12="$TMPDIR/platform.p12"

echo "==> Converting PKCS#8 DER private key to PEM"
openssl pkcs8 -inform DER -in "$PK8" -out "$KEY_PEM" -nocrypt

echo "==> Creating PKCS#12 bundle"
openssl pkcs12 -export \
  -in "$PEM" \
  -inkey "$KEY_PEM" \
  -out "$P12" \
  -name platform \
  -password pass:android

echo "==> Importing into JKS: $JKS"
# Remove existing JKS so keytool does not prompt for overwrite
rm -f "$JKS"
keytool -importkeystore \
  -srckeystore "$P12" -srcstoretype PKCS12 -srcstorepass android \
  -destkeystore "$JKS" -deststoretype JKS -deststorepass android \
  -alias platform -destkeypass android \
  -noprompt 2>&1 | grep -v "Warning:" | grep -v "uses the MD5withRSA" | grep -v "proprietary format" | grep -v "Migrating" || true

chmod 600 "$JKS" 2>/dev/null || true

echo "==> Verifying certificate SHA-256"
# Extract SHA256 fingerprint via keytool
ACTUAL_SHA256="$(keytool -list -v -keystore "$JKS" -storepass android 2>/dev/null \
  | grep -i "SHA256:" | head -1 | sed 's/.*SHA256: //' | tr -d ':' | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"

if [[ -z "$ACTUAL_SHA256" ]]; then
  die "Failed to read certificate SHA-256 from generated keystore"
fi

if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
  echo "WARNING: Generated keystore SHA-256 does not match expected!" >&2
  echo "  Expected: $EXPECTED_SHA256" >&2
  echo "  Actual:   $ACTUAL_SHA256" >&2
  exit 1
fi

echo "OK: $JKS"
echo "    SHA-256: $ACTUAL_SHA256"
echo "    Alias: platform, passwords: android"
