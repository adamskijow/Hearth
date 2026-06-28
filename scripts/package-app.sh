#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Assemble a Hearth.app bundle from a release build.
#
# This produces an unsigned bundle under dist/. A proper distribution build is
# Developer ID signed and notarized; those steps need an Apple Developer account
# and are left as a clearly marked stub at the bottom of this script. The Mac App
# Store is intentionally not a target: Hearth spawns and supervises another
# process, which the App Sandbox forbids.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Hearth"
BUNDLE_ID="com.hearth.Hearth"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "Building release..."
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)"

echo "Assembling $APP ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN_PATH/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "Sources/Hearth/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "Done: $APP (unsigned)"
echo
echo "Run it with:  open $APP"
echo "A menubar item appears; there is no Dock icon (LSUIElement)."
echo
echo "This bundle is unsigned. For a distributable, Developer ID signed and"
echo "notarized build, use scripts/release.sh."
