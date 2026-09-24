#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXTRACTOR="$ROOT_DIR/scripts/extract_apk_certificate_sha256.sh"
EXPECTED="c8a2e9bccf597c2fb6dc66bee293fc13f2fc47ec77bc6b2b0d52c11f51192ab8"

assert_digest() {
    local description="$1"
    local output="$2"
    local actual
    actual="$(printf '%s\n' "$output" | "$EXTRACTOR")"
    [[ "$actual" == "$EXPECTED" ]] || {
        echo "$description: expected $EXPECTED, got $actual" >&2
        exit 1
    }
}

assert_rejected() {
    local description="$1"
    local output="$2"
    if printf '%s\n' "$output" | "$EXTRACTOR" >/dev/null 2>&1; then
        echo "$description: invalid signer output was accepted" >&2
        exit 1
    fi
}

assert_digest "legacy apksigner format" \
    "Signer #1 certificate SHA-256 digest: $EXPECTED"
assert_digest "versioned apksigner format" \
    "V3.0 Signer: certificate SHA-256 digest: $EXPECTED"
assert_rejected "missing certificate" "Number of signers: 1"
assert_rejected "multiple certificates" \
    $'Signer #1 certificate SHA-256 digest: '"$EXPECTED"$'\nSigner #2 certificate SHA-256 digest: '"$EXPECTED"

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
printf 'test apk' > "$TEMP_DIR/app.apk"
cat > "$TEMP_DIR/notes.json" <<'EOF'
{
  "en": ["English note"],
  "pt": ["Nota em português"],
  "ru": ["Примечание"]
}
EOF
"$ROOT_DIR/scripts/create_release_manifest.sh" \
    "$TEMP_DIR/app.apk" \
    1.2.3 \
    123 \
    "https://github.com/example/capy_releases/releases/download/v1.2.3/capy-v1.2.3.apk" \
    "$TEMP_DIR/latest.json" \
    false \
    "$TEMP_DIR/notes.json" >/dev/null
jq -e \
    '.schemaVersion == 1 and
     .changelog[0].versionName == "1.2.3" and
     .changelog[0].versionCode == 123 and
     .changelog[0].notes.pt[0] == "Nota em português"' \
    "$TEMP_DIR/latest.json" >/dev/null
"$ROOT_DIR/scripts/create_release_manifest.sh" \
    "$TEMP_DIR/app.apk" \
    1.2.3 \
    123 \
    "https://github.com/example/capy_releases/releases/download/v1.2.3/capy-v1.2.3.apk" \
    "$TEMP_DIR/latest-without-notes.json" >/dev/null
jq -e 'has("changelog") | not' "$TEMP_DIR/latest-without-notes.json" >/dev/null

echo "Release tool tests passed"
