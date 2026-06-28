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
# And notarization credentials, either a stored keychain profile:
#   HEARTH_NOTARY_PROFILE  a notarytool keychain profile created with
#                          `xcrun notarytool store-credentials`
# or an App Store Connect API key passed directly (works in non-interactive
# contexts where storing a keychain profile is blocked):
#   HEARTH_NOTARY_KEY      path to the AuthKey_XXXX.p8 private key
#   HEARTH_NOTARY_KEY_ID   the key ID (the XXXX in the filename)
#   HEARTH_NOTARY_ISSUER   the App Store Connect issuer ID (a UUID)
# Optional:
#   HEARTH_VERSION         overrides the version read from Info.plist
set -euo pipefail

cd "$(dirname "$0")/.."

: "${HEARTH_SIGN_IDENTITY:?Set HEARTH_SIGN_IDENTITY to your Developer ID Application identity}"

if [ -n "${HEARTH_NOTARY_PROFILE:-}" ]; then
  NOTARY_AUTH=(--keychain-profile "$HEARTH_NOTARY_PROFILE")
elif [ -n "${HEARTH_NOTARY_KEY:-}" ] && [ -n "${HEARTH_NOTARY_KEY_ID:-}" ] && [ -n "${HEARTH_NOTARY_ISSUER:-}" ]; then
  NOTARY_AUTH=(--key "$HEARTH_NOTARY_KEY" --key-id "$HEARTH_NOTARY_KEY_ID" --issuer "$HEARTH_NOTARY_ISSUER")
else
  echo "Set HEARTH_NOTARY_PROFILE, or all of HEARTH_NOTARY_KEY, HEARTH_NOTARY_KEY_ID, HEARTH_NOTARY_ISSUER." >&2
  exit 2
fi

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
xcrun notarytool submit "$ZIP" "${NOTARY_AUTH[@]}" --wait

echo "Stapling and re-zipping the stapled bundle..."
xcrun stapler staple "$APP"

echo "Verifying Gatekeeper acceptance (offline, via the stapled ticket)..."
spctl --assess --type exec --verbose=4 "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Building the DMG from the notarized, stapled app..."
DMG="$(HEARTH_VERSION="$VERSION" HEARTH_SIGN_IDENTITY="$HEARTH_SIGN_IDENTITY" ./scripts/make-dmg.sh)"

echo "Notarizing the DMG..."
xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait
xcrun stapler staple "$DMG"

echo "Verifying Gatekeeper acceptance of the DMG..."
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

DMG_SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
ZIP_SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo
echo "Release artifacts (both signed, notarized, stapled):"
echo "  $DMG"
echo "    sha256: $DMG_SHA"
echo "  $ZIP"
echo "    sha256: $ZIP_SHA"
echo "Version: $VERSION"
echo
echo "Next: set Casks/hearth.rb version and sha256 to the DMG's, and attach both"
echo "artifacts to the GitHub release. The cask installs from the DMG."
