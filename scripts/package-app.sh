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

echo "Done: $APP"
echo
echo "Run it with:  open $APP"
echo "A menubar item appears; there is no Dock icon (LSUIElement)."
echo

# ---------------------------------------------------------------------------
# STUB: Developer ID signing and notarization (not run by default).
#
# Hardened Runtime is required for notarization. App Sandbox stays OFF because
# the whole job is supervising a child process.
#
# Fill in your signing identity and an App Store Connect API key / notarytool
# profile, then uncomment:
#
# SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
# codesign --force --options runtime --timestamp \
#   --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/$APP_NAME"
# codesign --force --options runtime --timestamp \
#   --sign "$SIGN_IDENTITY" "$APP"
#
# ditto -c -k --keepParent "$APP" "$DIST/$APP_NAME.zip"
# xcrun notarytool submit "$DIST/$APP_NAME.zip" \
#   --keychain-profile "HearthNotary" --wait
# xcrun stapler staple "$APP"
# ---------------------------------------------------------------------------
