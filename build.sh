#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

xcodebuild -quiet -scheme QuickChat -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$PWD/.build/xcode" CODE_SIGNING_ALLOWED=NO "ARCHS=$(uname -m)"
BIN_DIR="$PWD/.build/xcode/Build/Products/Release"
FINAL="$PWD/build/Quick Chat.app"
mkdir -p "$PWD/build"
STAGING=$(mktemp -d "$PWD/build/.staging.XXXXXX")
trap 'rm -rf -- "$STAGING"' EXIT
APP="$STAGING/Quick Chat.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/QuickChat" "$APP/Contents/MacOS/QuickChat"
cp Info.plist "$APP/Contents/Info.plist"

# Xcode's SwiftPM accessors look in the app's standard Resources directory.
BUNDLE="$BIN_DIR/QuickChat_QuickChat.bundle"
if [[ ! -d "$BUNDLE" ]]; then
    echo "SwiftPM did not produce $BUNDLE." >&2
    exit 1
fi
ditto "$BUNDLE" "$APP/Contents/Resources/QuickChat_QuickChat.bundle"

codesign --force --sign "${CODE_SIGN_IDENTITY:--}" "$APP"
if [[ -e "$FINAL" ]]; then mv "$FINAL" "$STAGING/previous.app"; fi
mv "$APP" "$FINAL"
printf '%s\n' "$FINAL"
