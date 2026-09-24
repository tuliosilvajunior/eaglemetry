#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  scripts/create_release_manifest.sh \
    APK_PATH VERSION_NAME VERSION_CODE APK_URL OUTPUT_PATH \
    [REQUIRES_REFLASH] [RELEASE_NOTES_PATH]

Generates the public latest.json manifest consumed by the app updater.
REQUIRES_REFLASH defaults to false.
RELEASE_NOTES_PATH is an optional JSON object with en, pt, and ru string lists.
EOF
}

[[ $# -ge 5 && $# -le 7 ]] || {
    usage >&2
    exit 2
}

APK_PATH="$1"
VERSION_NAME="$2"
VERSION_CODE="$3"
APK_URL="$4"
OUTPUT_PATH="$5"
REQUIRES_REFLASH="${6:-false}"
RELEASE_NOTES_PATH="${7:-}"

[[ -f "$APK_PATH" ]] || {
    echo "APK not found: $APK_PATH" >&2
    exit 1
}
[[ "$VERSION_NAME" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
    echo "Invalid versionName: $VERSION_NAME" >&2
    exit 1
}
[[ "$VERSION_CODE" =~ ^[1-9][0-9]*$ ]] || {
    echo "Invalid versionCode: $VERSION_CODE" >&2
    exit 1
}
[[ "$APK_URL" == https://* ]] || {
    echo "APK URL must use HTTPS: $APK_URL" >&2
    exit 1
}
[[ "$REQUIRES_REFLASH" == "true" || "$REQUIRES_REFLASH" == "false" ]] || {
    echo "REQUIRES_REFLASH must be true or false" >&2
    exit 1
}
command -v jq >/dev/null || {
    echo "jq is required" >&2
    exit 1
}

RELEASE_NOTES_JSON="null"
if [[ -n "$RELEASE_NOTES_PATH" ]]; then
    [[ -f "$RELEASE_NOTES_PATH" ]] || {
        echo "Release notes not found: $RELEASE_NOTES_PATH" >&2
        exit 1
    }
    for locale in en pt ru; do
        jq -e --arg locale "$locale" \
            '.[$locale] | type == "array" and length > 0 and length <= 20 and
            all(.[]; type == "string" and length > 0 and length <= 240)' \
            "$RELEASE_NOTES_PATH" >/dev/null || {
            echo "Invalid $locale release notes in $RELEASE_NOTES_PATH" >&2
            exit 1
        }
    done
    RELEASE_NOTES_JSON="$(jq -c '{en, pt, ru}' "$RELEASE_NOTES_PATH")"
fi

if command -v sha256sum >/dev/null; then
    SHA256="$(sha256sum "$APK_PATH" | awk '{print $1}')"
else
    SHA256="$(shasum -a 256 "$APK_PATH" | awk '{print $1}')"
fi

SIZE_BYTES="$(wc -c < "$APK_PATH" | tr -d '[:space:]')"

jq -n \
    --arg versionName "$VERSION_NAME" \
    --argjson versionCode "$VERSION_CODE" \
    --arg packageName "com.timhss.capy" \
    --arg apkUrl "$APK_URL" \
    --arg sha256 "$SHA256" \
    --argjson sizeBytes "$SIZE_BYTES" \
    --argjson requiresReflash "$REQUIRES_REFLASH" \
    --argjson releaseNotes "$RELEASE_NOTES_JSON" \
    '{
        schemaVersion: 1,
        versionName: $versionName,
        versionCode: $versionCode,
        packageName: $packageName,
        apkUrl: $apkUrl,
        sha256: $sha256,
        sizeBytes: $sizeBytes,
        requiresReflash: $requiresReflash
    } + if $releaseNotes == null then {} else {
        changelog: [{
            versionName: $versionName,
            versionCode: $versionCode,
            notes: $releaseNotes
        }]
    } end' > "$OUTPUT_PATH"

echo "Created $OUTPUT_PATH for $VERSION_NAME ($VERSION_CODE)"
