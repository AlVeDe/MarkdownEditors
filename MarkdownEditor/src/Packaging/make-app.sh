#!/bin/zsh
# Builds the SwiftPM executable and wraps it in MarkdownEditor.app.
#
#   Packaging/make-app.sh [debug|release] [version]
#
# Output: dist/<configuration>/MarkdownEditor.app (path printed on the last line)
#
# The app is a document app: macOS learns from Info.plist which files it
# opens, so it has to run as a bundle — a bare `swift run` binary cannot open
# or save documents.
set -euo pipefail

APP_NAME="MarkdownEditor"
CONFIGURATION="${1:-debug}"
VERSION="${2:-1.0}"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

ROOT="${0:A:h:h}"
APP="$ROOT/dist/$CONFIGURATION/$APP_NAME.app"

# SwiftUI's macros (@State, @Entry, …) ship with Xcode, not with the Command
# Line Tools; use Xcode's toolchain when xcode-select points elsewhere.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

cd "$ROOT"

echo "▸ Building ($CONFIGURATION)" >&2
swift build -c "$CONFIGURATION" >&2
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

echo "▸ Assembling $APP_NAME.app" >&2
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
# SwiftPM resource bundle (Sample.md, mermaid.js, MathJax) — looked up in
# Contents/Resources by `Bundle.resources`.
cp -R "$BIN_DIR/${APP_NAME}_${APP_NAME}.bundle" "$APP/Contents/Resources/"
cp "$ROOT/Packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" \
    "$ROOT/Packaging/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ Signing (ad hoc)" >&2
codesign --force --deep --sign - --timestamp=none "$APP" 2>/dev/null
codesign --verify --deep --strict "$APP"

echo "$APP"
