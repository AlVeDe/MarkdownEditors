#!/bin/zsh
# Builds MarkdownEditor.app (release) and packs it into a drag-to-install DMG.
#
#   Packaging/build-dmg.sh [version]      # default version: 1.0
#
# Output: dist/release/MarkdownEditor.app and dist/MarkdownEditor-<version>.dmg
set -euo pipefail

APP_NAME="MarkdownEditor"
VERSION="${1:-1.0}"
ROOT="${0:A:h:h}"
DMG="$ROOT/dist/$APP_NAME-$VERSION.dmg"

APP="$("$ROOT/Packaging/make-app.sh" release "$VERSION" | tail -1)"

echo "▸ Creating $DMG:t"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -fs HFS+ \
    -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null 2>&1

echo "✓ $DMG"
