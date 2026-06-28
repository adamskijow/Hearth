#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Build a drag-to-install DMG from dist/Hearth.app: the app plus an Applications
# shortcut, so the mounted window is the familiar "drag Hearth into Applications"
# layout. Uses only hdiutil (no external tooling).
#
# If HEARTH_SIGN_IDENTITY is set the DMG is codesigned; scripts/release.sh then
# notarizes and staples it. Run on its own to produce an unsigned local DMG.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="dist/Hearth.app"
[ -d "$APP" ] || { echo "No $APP. Run scripts/package-app.sh first." >&2; exit 1; }

VERSION="${HEARTH_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/Hearth/Resources/Info.plist)}"
DMG="dist/Hearth-$VERSION.dmg"
VOLUME="Hearth"

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "$VOLUME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"

if [ -n "${HEARTH_SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$HEARTH_SIGN_IDENTITY" "$DMG"
fi

echo "$DMG"
