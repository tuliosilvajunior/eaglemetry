#!/usr/bin/env bash
set -euo pipefail

# Manual release, end to end, for when GitHub Actions cannot run it.
#
# This is the same pipeline as `.github/workflows/release.yml`, in one script
# you can watch. It resolves the version, builds the signed APK, runs every
# check the workflow runs plus the ones that only a local run can do, and stops
# for a confirmation before anything leaves this machine.
#
# Nothing is published, committed, tagged, or pushed before that prompt. Up to
# it the script only writes inside `dist/` and `pubspec.yaml`, and `pubspec.yaml`
# is restored on any failure.

PACKAGE_NAME="com.timhss.capy"
# Your public releases repository (owner/repo). The app updater reads
# APP_UPDATE_MANIFEST_URL; keep this and that manifest URL on the same repo.
PUBLIC_RELEASE_REPOSITORY="${PUBLIC_RELEASE_REPOSITORY:-example/capy_releases}"

# The platform certificate. An APK signed with anything else cannot join
# `android.uid.system`, so the car would reject it. `.github/workflows/
# release.yml` pins the same value; the two must be changed together.
EXPECTED_SIGNING_CERT_SHA256="c8a2e9bccf597c2fb6dc66bee293fc13f2fc47ec77bc6b2b0d52c11f51192ab8"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
# The public release checkout (a clone of PUBLIC_RELEASE_REPOSITORY).
# Set RELEASES_DIR explicitly; the sibling path is only a convenience guess.
if [[ -z "${RELEASES_DIR:-}" ]]; then
    if [[ -d "$ROOT_DIR/../capy_releases" ]]; then
        RELEASES_DIR="$ROOT_DIR/../capy_releases"
    else
        RELEASES_DIR="$HOME/capy_releases"
    fi
fi
KEYSTORE_PATH="${PLATFORM_KEYSTORE_PATH:-$ROOT_DIR/refs/aosp-security/platform.jks}"
EXPECTED_FLUTTER_VERSION="3.44.6"

BUMP="auto"
VERSION_OVERRIDE=""
ASSUME_YES=0
SKIP_BUILD=0
TAG_SOURCE=0

usage() {
    cat <<'EOF'
Usage: scripts/release_manual.sh [options]

Builds, checks and publishes a release by hand. Mirrors the GitHub Actions
pipeline, and stops for a confirmation before publishing.

Options:
  --bump LEVEL      major | minor | patch | auto. Default auto, which reads the
                    commits since the last v* tag: "feat!:" or BREAKING CHANGE
                    gives major, "feat:" gives minor, anything else patch.
  --version X.Y.Z   Use this version instead of deriving one.
  --no-build        Reuse the APK already in build/. For a second run after a
                    check failed for a reason outside the build.
  --tag-source      Also create the "chore(release): vX.Y.Z" commit and tag on
                    the current branch, after publishing. Not pushed.
  --yes             Skip the confirmation. For unattended runs only.
  -h, --help        Show this help.

Environment:
  RELEASES_DIR              Public release checkout. Default ../capy_releases,
                            else ~/capy_releases. Set it explicitly.
  PLATFORM_KEYSTORE_PATH    Signing keystore. Default is the AOSP platform key.

The versionCode is the repository's total commit count, which is what the
workflow uses. It must never go down: the updater on the car refuses a version
code at or below the one it already runs.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bump) BUMP="${2:-}"; shift 2 ;;
        --version) VERSION_OVERRIDE="${2:-}"; shift 2 ;;
        --no-build) SKIP_BUILD=1; shift ;;
        --tag-source) TAG_SOURCE=1; shift ;;
        --yes) ASSUME_YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()   { printf '    \033[32mOK\033[0m    %s\n' "$1"; }
info() { printf '          %s\n' "$1"; }
die()  { printf '    \033[31mFAIL\033[0m  %s\n' "$1" >&2; exit 1; }

# pubspec.yaml is the only tracked file this script edits before the prompt.
# Restoring it on any exit path keeps a failed run from leaving a half-applied
# version behind.
PUBSPEC_SAVED=""
PUBSPEC_COMMITTED=0
restore_pubspec() {
    if [[ -n "$PUBSPEC_SAVED" && $PUBSPEC_COMMITTED -eq 0 ]]; then
        cp "$PUBSPEC_SAVED" "$ROOT_DIR/pubspec.yaml"
        printf '\n    pubspec.yaml restored.\n'
    fi
    [[ -n "$PUBSPEC_SAVED" ]] && rm -f "$PUBSPEC_SAVED"
}
trap restore_pubspec EXIT

cd "$ROOT_DIR"

# ---------------------------------------------------------------------------
step "1/10  Preflight"

for tool in flutter jq git shasum; do
    command -v "$tool" >/dev/null || die "$tool not found"
done
ok "flutter, jq, git, shasum"

# The build tools are versioned directories; the newest is what CI resolves to.
SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
APKSIGNER="$(find "$SDK_ROOT/build-tools" -type f -name apksigner 2>/dev/null | sort -V | tail -1)"
AAPT2="$(find "$SDK_ROOT/build-tools" -type f -name aapt2 2>/dev/null | sort -V | tail -1)"
[[ -n "$APKSIGNER" ]] || die "apksigner not found under $SDK_ROOT/build-tools"
[[ -n "$AAPT2" ]] || die "aapt2 not found under $SDK_ROOT/build-tools"
ok "apksigner $(basename "$(dirname "$APKSIGNER")")"

if [[ ! -f "$KEYSTORE_PATH" ]]; then
    die "Platform keystore not found: $KEYSTORE_PATH — this is the public AOSP test platform key (alias platform, passwords android), not a secret . Run scripts/generate_platform_keystore.sh to create refs/aosp-security/platform.jks, or set PLATFORM_KEYSTORE_PATH."
fi
ok "keystore present"

[[ -d "$RELEASES_DIR" ]] || die "releases checkout not found: $RELEASES_DIR"
ok "releases checkout at $RELEASES_DIR"

# The versionCode is the commit count. A shallow clone counts only the commits
# it fetched, so the code comes out low and every car refuses the update.
[[ "$(git rev-parse --is-shallow-repository)" == "false" ]] \
    || die "shallow clone: the commit count is wrong. Run: git fetch --unshallow --tags origin"
ok "full history"

# Build-time configuration. The Dart side reads SUPABASE_* through
# --dart-define-from-file=.env (the sync screen's backend probe); the Android
# side reads them from local.properties into BuildConfig. A release without
# them ships a car that cannot reach the cloud.
ENV_FILE="$ROOT_DIR/.env"
[[ -f "$ENV_FILE" ]] || die "$ENV_FILE not found; copy .env.example and fill it in"
env_value() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$2" | tail -1; }
[[ -n "$(env_value SUPABASE_URL "$ENV_FILE")" ]] || die "SUPABASE_URL is empty in .env"
[[ -n "$(env_value SUPABASE_PUBLISHABLE_KEY "$ENV_FILE")$(env_value SUPABASE_ANON_KEY "$ENV_FILE")" ]] \
    || die "no SUPABASE_PUBLISHABLE_KEY or SUPABASE_ANON_KEY in .env"
LOCAL_PROPS="$ROOT_DIR/android/local.properties"
for key in SUPABASE_URL SUPABASE_ANON_KEY SUPABASE_FUNCTIONS_URL; do
    [[ -n "$(env_value "$key" "$LOCAL_PROPS")${!key:-}" ]] \
        || die "$key is missing from android/local.properties and the environment"
done
# Standing owner decision: the cloud stays on in production.
for file in "$ENV_FILE" "$LOCAL_PROPS"; do
    [[ "$(env_value CLOUD_SYNC_ENABLED "$file")" != "false" ]] \
        || die "$file pins CLOUD_SYNC_ENABLED=false"
done
ok ".env and android/local.properties carry the Supabase configuration"

FLUTTER_VERSION="$(flutter --version 2>/dev/null | sed -n '1s/^Flutter \([0-9.]*\).*/\1/p')"
if [[ "$FLUTTER_VERSION" != "$EXPECTED_FLUTTER_VERSION" ]]; then
    info "WARNING: Flutter $FLUTTER_VERSION, workflow pins $EXPECTED_FLUTTER_VERSION."
    info "A different toolchain can produce a different APK. Continuing."
else
    ok "flutter $FLUTTER_VERSION matches the workflow"
fi

# Two files may be dirty, and nothing else. pubspec.yaml because a previous run
# of this script may have set it, and the release notes because writing them is
# part of preparing a release rather than something that precedes it. Any other
# tracked change means the build would not match a commit, and the release
# could never be reproduced from the tag.
DIRTY="$(git status --porcelain \
    | grep -v '^?? ' \
    | grep -vE ' (pubspec\.yaml|release_notes/current\.json)$' || true)"
[[ -z "$DIRTY" ]] || {
    printf '%s\n' "$DIRTY" >&2
    die "working tree has tracked changes; commit or stash them first"
}
ok "working tree clean"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
HEAD_SHA="$(git rev-parse --short HEAD)"
info "branch $BRANCH at $HEAD_SHA"

# ---------------------------------------------------------------------------
step "2/10  Resolve version"

LAST_TAG="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
if [[ -n "$LAST_TAG" ]]; then
    BASE="${LAST_TAG#v}"
    RANGE="$LAST_TAG..HEAD"
    info "last tag $LAST_TAG"
else
    BASE="$(sed -n 's/^version: \([0-9.]*\)+.*/\1/p' pubspec.yaml)"
    RANGE="HEAD"
    info "no tag found; base is pubspec $BASE"
fi

if [[ -n "$VERSION_OVERRIDE" ]]; then
    [[ "$VERSION_OVERRIDE" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die "invalid --version: $VERSION_OVERRIDE"
    VERSION="$VERSION_OVERRIDE"
    info "version forced to $VERSION"
else
    COMMITS="$(git log --format='%s%n%b' "$RANGE")"
    [[ -n "$(git log --format='%h' "$RANGE")" ]] \
        || die "no commits since $LAST_TAG; nothing to release"
    if [[ "$BUMP" == "auto" ]]; then
        if grep -qE '^[a-z]+(\([^)]*\))?!:|BREAKING CHANGE' <<< "$COMMITS"; then
            BUMP=major
        elif grep -qE '^feat(\([^)]*\))?:' <<< "$COMMITS"; then
            BUMP=minor
        else
            BUMP=patch
        fi
        info "derived bump: $BUMP"
    fi
    IFS=. read -r MAJOR MINOR PATCH <<< "$BASE"
    case "$BUMP" in
        major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
        minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
        patch) PATCH=$((PATCH + 1)) ;;
        *) die "invalid bump: $BUMP" ;;
    esac
    VERSION="$MAJOR.$MINOR.$PATCH"
fi

VERSION_CODE="$(git rev-list --count HEAD)"
TAG="v$VERSION"
ASSET_NAME="capy-v$VERSION.apk"
APK_URL="https://github.com/$PUBLIC_RELEASE_REPOSITORY/releases/download/$TAG/$ASSET_NAME"
ok "$BASE -> $VERSION+$VERSION_CODE"

# A version code that does not rise leaves every car unable to update, and the
# failure is silent on the car. Checked against what is actually published, not
# against the local file, which can lag.
PUBLISHED_CODE=""
PUBLISHED_NAME=""
PUBLISHED_MANIFEST="$(mktemp)"
if command -v gh >/dev/null && gh release download --repo "$PUBLIC_RELEASE_REPOSITORY" \
    --pattern latest.json --output "$PUBLISHED_MANIFEST" --clobber 2>/dev/null; then
    info "compared against the latest release on GitHub"
elif [[ -f "$RELEASES_DIR/latest.json" ]]; then
    cp "$RELEASES_DIR/latest.json" "$PUBLISHED_MANIFEST"
    info "WARNING: could not read GitHub; compared against the local $RELEASES_DIR/latest.json"
else
    : > "$PUBLISHED_MANIFEST"
fi
if [[ -s "$PUBLISHED_MANIFEST" ]]; then
    PUBLISHED_CODE="$(jq -r '.versionCode // empty' "$PUBLISHED_MANIFEST")"
    PUBLISHED_NAME="$(jq -r '.versionName // empty' "$PUBLISHED_MANIFEST")"
fi
rm -f "$PUBLISHED_MANIFEST"
REPUBLISH=0
if [[ -n "$PUBLISHED_CODE" ]]; then
    if (( VERSION_CODE < PUBLISHED_CODE )); then
        die "versionCode $VERSION_CODE is below the published $PUBLISHED_CODE; cars would refuse the update"
    elif (( VERSION_CODE == PUBLISHED_CODE )); then
        # Equal is only ever right when this is the same release being built
        # again. The same code under a different name would leave two different
        # APKs indistinguishable to the updater.
        [[ "$VERSION" == "$PUBLISHED_NAME" ]] \
            || die "versionCode $VERSION_CODE is already published as $PUBLISHED_NAME, not $VERSION"
        REPUBLISH=1
        info "republishing $VERSION+$VERSION_CODE over the existing release"
    else
        ok "versionCode rises: $PUBLISHED_CODE -> $VERSION_CODE"
    fi
fi

if git rev-parse --verify "refs/tags/$TAG" >/dev/null 2>&1; then
    info "WARNING: tag $TAG already exists locally."
fi

# A release tag is not always on a branch (the --tag-source commit is not
# pushed), so "last tag" can lag and derive a name that is already published.
# Publishing would then overwrite that release's APK under a new code.
if [[ $REPUBLISH -eq 0 ]] && command -v gh >/dev/null \
    && gh release view "$TAG" --repo "$PUBLIC_RELEASE_REPOSITORY" >/dev/null 2>&1; then
    die "release $TAG is already published with a different build; pass --version with a new version"
fi

# ---------------------------------------------------------------------------
step "3/10  Release notes"

NOTES_PATH="release_notes/current.json"
[[ -f "$NOTES_PATH" ]] || die "$NOTES_PATH not found"
for locale in en pt ru; do
    jq -e --arg l "$locale" \
        '.[$l] | type == "array" and length > 0 and length <= 12 and
         all(.[]; type == "string" and (. | length) > 0 and (. | length) <= 240)' \
        "$NOTES_PATH" >/dev/null || die "invalid $locale notes in $NOTES_PATH"
done
ok "en, pt, ru present and within limits"
jq -r '.pt[] | "          - " + .' "$NOTES_PATH"

# ---------------------------------------------------------------------------
step "4/10  Build signed APK"

PUBSPEC_SAVED="$(mktemp)"
cp pubspec.yaml "$PUBSPEC_SAVED"
sed -i '' "s/^version: .*/version: $VERSION+$VERSION_CODE/" pubspec.yaml
ok "pubspec set to $VERSION+$VERSION_CODE"

BUILT_APK="build/app/outputs/flutter-apk/app-release.apk"
if [[ $SKIP_BUILD -eq 1 ]]; then
    [[ -f "$BUILT_APK" ]] || die "--no-build given but $BUILT_APK is missing"
    info "reusing the existing APK"
else
    flutter pub get >/dev/null
    PLATFORM_KEYSTORE_PATH="$KEYSTORE_PATH" \
        flutter build apk --release --target-platform android-arm64 \
        --dart-define-from-file="$ENV_FILE" \
        || die "build failed"
    ok "built $BUILT_APK"
fi

# ---------------------------------------------------------------------------
step "5/10  Verify signature"

VERIFICATION="$("$APKSIGNER" verify --verbose --print-certs "$BUILT_APK")"
CERT_SHA="$(scripts/extract_apk_certificate_sha256.sh <<< "$VERIFICATION")"
[[ "$CERT_SHA" == "$EXPECTED_SIGNING_CERT_SHA256" ]] \
    || die "unexpected signing certificate: $CERT_SHA"
ok "certificate $CERT_SHA"

# The schemes are compared against the newest published APK rather than
# demanded outright. This build signs v3 only, and so does every release the
# car already runs; a bare "v1 must verify" check would fail a good build. What
# would be a real regression is this APK verifying under fewer schemes than the
# one in the field.
SCHEMES_NOW="$(grep -E '^Verified using' <<< "$VERIFICATION")"
PREVIOUS_APK="$(find "$RELEASES_DIR" -maxdepth 1 -name 'capy-v*.apk' \
    ! -name "$ASSET_NAME" | sort -V | tail -1)"
if [[ -n "$PREVIOUS_APK" ]]; then
    SCHEMES_WAS="$("$APKSIGNER" verify --verbose --print-certs "$PREVIOUS_APK" \
        2>/dev/null | grep -E '^Verified using' || true)"
    if [[ "$SCHEMES_NOW" == "$SCHEMES_WAS" ]]; then
        ok "signature schemes match $(basename "$PREVIOUS_APK")"
    else
        info "WARNING: signature schemes differ from $(basename "$PREVIOUS_APK"):"
        diff <(printf '%s\n' "$SCHEMES_WAS") <(printf '%s\n' "$SCHEMES_NOW") \
            | sed 's/^/          /' || true
    fi
fi

# Without this the package cannot join the system uid, and every car permission
# it declares is refused.
#
# The dump is captured before it is searched, rather than piped into `grep -q`.
# `grep -q` exits on the first match, aapt2 then dies of SIGPIPE, and `pipefail`
# turns that into a failed pipeline — which reads exactly like a missing
# sharedUserId.
MANIFEST_TREE="$("$AAPT2" dump xmltree --file AndroidManifest.xml "$BUILT_APK" 2>/dev/null || true)"
grep -F 'sharedUserId' <<< "$MANIFEST_TREE" | grep -Fq '"android.uid.system"' \
    || die "sharedUserId android.uid.system is missing from the APK"
ok "sharedUserId android.uid.system"

# ---------------------------------------------------------------------------
step "6/10  Read the APK back"

BADGING="$("$AAPT2" dump badging "$BUILT_APK" 2>/dev/null)"
APK_PKG="$(sed -n "1s/^package: name='\([^']*\)'.*/\1/p" <<< "$BADGING")"
APK_VC="$(sed -n "1s/.*versionCode='\([0-9]*\)'.*/\1/p" <<< "$BADGING")"
APK_VN="$(sed -n "1s/.*versionName='\([^']*\)'.*/\1/p" <<< "$BADGING")"
APK_ABI="$(sed -n "s/^native-code: '\(.*\)'$/\1/p" <<< "$BADGING")"

[[ "$APK_PKG" == "$PACKAGE_NAME" ]] || die "APK package is $APK_PKG"
[[ "$APK_VC" == "$VERSION_CODE" ]] || die "APK versionCode is $APK_VC, expected $VERSION_CODE"
[[ "$APK_VN" == "$VERSION" ]] || die "APK versionName is $APK_VN, expected $VERSION"
[[ "$APK_ABI" == "arm64-v8a" ]] || die "APK ABI is '$APK_ABI', expected arm64-v8a"
ok "$APK_PKG $APK_VN+$APK_VC $APK_ABI"

# ---------------------------------------------------------------------------
step "7/10  Generate the manifest"

mkdir -p "$DIST_DIR"
rm -f "$DIST_DIR"/capy-v*.apk
cp "$BUILT_APK" "$DIST_DIR/$ASSET_NAME"
scripts/create_release_manifest.sh \
    "$DIST_DIR/$ASSET_NAME" "$VERSION" "$VERSION_CODE" "$APK_URL" \
    "$DIST_DIR/latest.json" false "$NOTES_PATH" >/dev/null
ok "dist/latest.json"

# ---------------------------------------------------------------------------
step "8/10  Cross-check the manifest against the APK"

M_SHA="$(jq -r .sha256 "$DIST_DIR/latest.json")"
A_SHA="$(shasum -a 256 "$DIST_DIR/$ASSET_NAME" | awk '{print $1}')"
M_SIZE="$(jq -r .sizeBytes "$DIST_DIR/latest.json")"
A_SIZE="$(wc -c < "$DIST_DIR/$ASSET_NAME" | tr -d '[:space:]')"

[[ "$M_SHA" == "$A_SHA" ]] || die "manifest sha256 $M_SHA != apk $A_SHA"
[[ "$M_SIZE" == "$A_SIZE" ]] || die "manifest sizeBytes $M_SIZE != apk $A_SIZE"
[[ "$(jq -r .versionCode "$DIST_DIR/latest.json")" == "$VERSION_CODE" ]] || die "manifest versionCode"
[[ "$(jq -r .versionName "$DIST_DIR/latest.json")" == "$VERSION" ]] || die "manifest versionName"
[[ "$(jq -r .packageName "$DIST_DIR/latest.json")" == "$PACKAGE_NAME" ]] || die "manifest packageName"
[[ "$(jq -r .apkUrl "$DIST_DIR/latest.json")" == "$APK_URL" ]] || die "manifest apkUrl"
ok "sha256, sizeBytes, versionCode, versionName, packageName, apkUrl"

# ---------------------------------------------------------------------------
step "9/10  Parse the manifest with the app's own parser"

# The checks above are this script's opinion of the manifest. This one is the
# car's: `AppUpdateManifest.parse` is the code that will read the file, and it
# enforces rules no external check knows about — the release URL prefix, the
# required locales, the changelog bounds. The test is written, run and deleted.
PARSER_DIR="android/app/src/test/kotlin/com/timhss/capyenergy/update"
RES_DIR="android/app/src/test/resources"
GATE_TEST="$PARSER_DIR/ReleaseManifestGateTest.kt"
GATE_RES="$RES_DIR/release_manifest_gate.json"
if [[ -d "$PARSER_DIR" ]]; then
    RES_DIR_CREATED=0
    [[ -d "$RES_DIR" ]] || { mkdir -p "$RES_DIR"; RES_DIR_CREATED=1; }
    cp "$DIST_DIR/latest.json" "$GATE_RES"
    cat > "$GATE_TEST" <<KOTLIN
package com.timhss.capyenergy.update

import org.junit.Assert.assertEquals
import org.junit.Test

/** Written and deleted by scripts/release_manual.sh. Do not commit. */
class ReleaseManifestGateTest {
    @Test
    fun theCandidateManifestParses() {
        val json = javaClass.classLoader!!
            .getResourceAsStream("release_manifest_gate.json")!!
            .bufferedReader().readText()
        val manifest = AppUpdateManifest.parse(json)
        assertEquals("$VERSION", manifest.versionName)
        assertEquals($VERSION_CODE, manifest.versionCode)
        assertEquals("$PACKAGE_NAME", manifest.packageName)
    }
}
KOTLIN
    cleanup_gate() {
        rm -f "$GATE_TEST" "$GATE_RES"
        [[ ${RES_DIR_CREATED:-0} -eq 1 ]] && rmdir "$RES_DIR" 2>/dev/null
        return 0
    }
    GATE_OUTPUT="$(cd android && ./gradlew --quiet :app:testDebugUnitTest \
        --tests '*ReleaseManifestGateTest*' 2>&1)" && GATE_STATUS=0 || GATE_STATUS=$?
    cleanup_gate
    if [[ $GATE_STATUS -ne 0 ]]; then
        printf '%s\n' "$GATE_OUTPUT" | tail -30 >&2
        die "the app's parser rejected the manifest"
    fi
    ok "AppUpdateManifest.parse accepted it"
else
    info "parser not found at $PARSER_DIR; skipped"
fi

# ---------------------------------------------------------------------------
step "10/10  Ready to publish"

cat <<SUMMARY

    version       $VERSION+$VERSION_CODE
    tag           $TAG
    branch        $BRANCH at $HEAD_SHA
    mode          $([[ $REPUBLISH -eq 1 ]] && echo "REPUBLISH over the existing $TAG" || echo "new release")
    apk           $DIST_DIR/$ASSET_NAME
    sha256        $A_SHA
    size          $A_SIZE bytes
    certificate   $CERT_SHA
    url           $APK_URL
    repository    $PUBLIC_RELEASE_REPOSITORY

    Publishing copies both files into $RELEASES_DIR and creates
    the GitHub release. Nothing has left this machine yet.

SUMMARY

if [[ $ASSUME_YES -eq 0 ]]; then
    read -r -p "    Publish $TAG? [y/N] " answer
    [[ "$answer" == "y" || "$answer" == "Y" ]] || {
        info "Stopped. dist/ holds the artifacts if you want to look."
        exit 0
    }
fi

command -v gh >/dev/null || die "gh is required to publish"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated"

step "Publishing"

cp "$DIST_DIR/$ASSET_NAME" "$RELEASES_DIR/$ASSET_NAME"
cp "$DIST_DIR/latest.json" "$RELEASES_DIR/latest.json"
ok "copied into $RELEASES_DIR"

NOTES="$(jq -r --arg v "$VERSION" --arg b "$VERSION_CODE" \
    '"Signed Android arm64 APK for Capy Energy v\($v) (versionCode \($b)).\n\n" +
     (.en | map("- " + .) | join("\n"))' "$NOTES_PATH")"

if gh release view "$TAG" --repo "$PUBLIC_RELEASE_REPOSITORY" >/dev/null 2>&1; then
    gh release upload "$TAG" --repo "$PUBLIC_RELEASE_REPOSITORY" --clobber \
        "$RELEASES_DIR/$ASSET_NAME" "$RELEASES_DIR/latest.json"
    gh release edit "$TAG" --repo "$PUBLIC_RELEASE_REPOSITORY" \
        --title "Capy Energy v$VERSION" --notes "$NOTES" --latest
    ok "updated the existing release $TAG"
else
    gh release create "$TAG" --repo "$PUBLIC_RELEASE_REPOSITORY" \
        --title "Capy Energy v$VERSION" --notes "$NOTES" --latest \
        "$RELEASES_DIR/$ASSET_NAME" "$RELEASES_DIR/latest.json"
    ok "created the release $TAG"
fi

# Read the manifest back from the release, so what the car will fetch is what
# was checked here, and not merely what was uploaded.
step "Verify what was published"
PUBLISHED="$(mktemp)"
if gh release download "$TAG" --repo "$PUBLIC_RELEASE_REPOSITORY" \
    --pattern latest.json --output "$PUBLISHED" --clobber 2>/dev/null; then
    if [[ "$(jq -r .sha256 "$PUBLISHED")" == "$A_SHA" \
       && "$(jq -r .versionCode "$PUBLISHED")" == "$VERSION_CODE" ]]; then
        ok "the published manifest matches this build"
    else
        info "WARNING: the published manifest does not match this build."
    fi
else
    info "could not read the manifest back; check the release by hand"
fi
rm -f "$PUBLISHED"

if [[ $TAG_SOURCE -eq 1 ]]; then
    step "Tag the source"
    git add pubspec.yaml
    git commit -m "chore(release): $TAG" >/dev/null
    git tag "$TAG"
    PUBSPEC_COMMITTED=1
    ok "committed and tagged $TAG on $BRANCH; not pushed"
    info "push with: git push origin $BRANCH $TAG"
fi

printf '\n\033[1m%s published.\033[0m\n\n' "$TAG"
