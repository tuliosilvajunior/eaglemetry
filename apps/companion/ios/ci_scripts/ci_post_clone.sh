#!/bin/sh
set -eo pipefail

# Xcode Cloud executes this script from the ci_scripts directory.
# Determine repository root
REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd ../../.. && pwd)}"

echo "=== [Xcode Cloud] Repository root: $REPO_ROOT ==="

# 1. Install Flutter SDK (channel stable)
echo "=== [Xcode Cloud] Installing Flutter SDK (stable) ==="
git clone https://github.com/flutter/flutter.git --depth 1 -b stable "$HOME/flutter"
export PATH="$PATH:$HOME/flutter/bin"

# Verify Flutter installation
flutter --version

# 2. Precache iOS artifacts
echo "=== [Xcode Cloud] Precaching iOS engine and artifacts ==="
flutter precache --ios

# 3. Install dependencies across Flutter workspace
echo "=== [Xcode Cloud] Running flutter pub get at workspace root ==="
cd "$REPO_ROOT"
flutter pub get

# 4. Generate iOS build configurations and ephemeral files for apps/companion
echo "=== [Xcode Cloud] Preparing iOS configuration for apps/companion ==="
cd "$REPO_ROOT/apps/companion"
flutter build ios --config-only --no-codesign

# 5. Run pod install if Podfile was generated/present
if [ -d "ios" ] && [ -f "ios/Podfile" ]; then
    echo "=== [Xcode Cloud] Running pod install in apps/companion/ios ==="
    cd ios
    pod install
fi

echo "=== [Xcode Cloud] Setup completed successfully! ==="
