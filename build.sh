#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Run the compiler macro from the pinned Equatable revision without a GUI trust prompt.
xcodebuild -quiet -scheme QuickChat -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$PWD/.build/xcode" -clonedSourcePackagesDirPath "$PWD/.build/xcode-packages" \
    -disableAutomaticPackageResolution -skipMacroValidation CODE_SIGNING_ALLOWED=NO "ARCHS=$(uname -m)"
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
shopt -s nullglob
bundles=("$BIN_DIR"/*.bundle)
if (( ${#bundles[@]} == 0 )); then
    echo 'SwiftPM did not produce the Markdown resource bundles.' >&2
    exit 1
fi
for bundle in "${bundles[@]}"; do
    ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
done

licenses="$APP/Contents/Resources/Licenses"
mkdir -p "$licenses"
for package in SwiftStreamingMarkdown highlightswift iosMath SwiftUI-Shimmer equatable swift-markdown swift-cmark; do
    for notice in "$PWD/.build/xcode-packages/checkouts/$package"/LICENSE* "$PWD/.build/xcode-packages/checkouts/$package"/COPYING; do
        if [[ -f "$notice" ]]; then cp "$notice" "$licenses/$package-$(basename "$notice")"; fi
    done
done
cp "$PWD/.build/xcode-packages/checkouts/iosMath/iosMath/fonts/GUST-FONT-LICENSE.txt" "$licenses/Latin-Modern-Math.txt"
cp "$PWD/.build/xcode-packages/checkouts/highlightswift/Sources/HighlightSwift/HighlightJS/LICENSE.md" "$licenses/highlight.js.md"

codesign --force --sign "${CODE_SIGN_IDENTITY:--}" "$APP"
if [[ -e "$FINAL" ]]; then mv "$FINAL" "$STAGING/previous.app"; fi
mv "$APP" "$FINAL"
printf '%s\n' "$FINAL"
