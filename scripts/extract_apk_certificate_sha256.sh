#!/usr/bin/env bash
set -euo pipefail

digests=()
while IFS= read -r digest; do
    digests+=("$digest")
done < <(sed -n 's/^.*certificate SHA-256 digest: //p')

if [[ ${#digests[@]} -ne 1 ]]; then
    echo "Expected exactly one APK signing certificate, found ${#digests[@]}" >&2
    exit 1
fi

digest="${digests[0]}"
[[ "$digest" =~ ^[0-9A-Fa-f]{64}$ ]] || {
    echo "Invalid APK signing certificate SHA-256: $digest" >&2
    exit 1
}

printf '%s\n' "$digest" | tr '[:upper:]' '[:lower:]'
