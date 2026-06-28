#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Build, Developer ID sign, notarize, staple, and zip Hearth.app.
#
# App Sandbox stays OFF (Hearth supervises another process, which the sandbox
# forbids) and the Hardened Runtime is ON, which notarization requires. The Mac
# App Store is not a target for the same reason.
#
# Requires:
#   HEARTH_SIGN_IDENTITY   Developer ID Application identity, e.g.
#                          "Developer ID Application: Your Name (TEAMID)"
#   HEARTH_NOTARY_PROFILE  a notarytool keychain profile created with
#                          `xcrun notarytool store-credentials`
# Optional:
#   HEARTH_VERSION         overrides the version read from Info.plist
set -euo pipefail

cd "$(dirname "$0")/.."

: "${HEARTH_SIGN_IDENTITY:?Set HEARTH_SIGN_IDENTITY to your Developer ID Application identity}"
: "${HEARTH_NOTARY_PROFILE:?Set HEARTH_NOTARY_PROFILE to a notarytool keychain profile}"

VERSION="${HEARTH_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/Hearth/Resources/Info.plist)}"
APP="dist/Hearth.app"
ZIP="dist/Hearth-$VERSION.zip"

./scripts/package-app.sh

echo "Signing with Hardened Runtime (App Sandbox stays off)..."
codesign --force --options runtime --timestamp --sign "$HEARTH_SIGN_IDENTITY" "$APP/Contents/MacOS/Hearth"
codesign --force --options runtime --timestamp --sign "$HEARTH_SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "Zipping for notarization..."
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Notarizing (this can take a few minutes)..."
xcrun notarytool submit "$ZIP" --keychain-profile "$HEARTH_NOTARY_PROFILE" --wait

echo "Stapling and re-zipping the stapled bundle..."
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo
echo "Release artifact: $ZIP"
echo "Version:          $VERSION"
echo "sha256:           $SHA"
echo
echo "Next: update Casks/hearth.rb (version and sha256) and attach $ZIP to the GitHub release."
