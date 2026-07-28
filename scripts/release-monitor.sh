#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Build, Developer ID sign, notarize, staple, and package the public GitHub
# edition of Hearth Monitor. This keeps the same App Sandbox boundary as the Mac
# App Store edition, but uses Developer ID distribution so the app can be
# downloaded directly from GitHub.
set -euo pipefail

cd "$(dirname "$0")/.."

SIGN_IDENTITY="${HEARTH_MONITOR_SIGN_IDENTITY:-${HEARTH_SIGN_IDENTITY:-}}"
: "${SIGN_IDENTITY:?Set HEARTH_MONITOR_SIGN_IDENTITY or HEARTH_SIGN_IDENTITY to a Developer ID Application identity}"

if [ -n "${HEARTH_NOTARY_PROFILE:-}" ]; then
  NOTARY_AUTH=(--keychain-profile "$HEARTH_NOTARY_PROFILE")
elif [ -n "${HEARTH_NOTARY_KEY:-}" ] \
  && [ -n "${HEARTH_NOTARY_KEY_ID:-}" ] \
  && [ -n "${HEARTH_NOTARY_ISSUER:-}" ]; then
  NOTARY_AUTH=(
    --key "$HEARTH_NOTARY_KEY"
    --key-id "$HEARTH_NOTARY_KEY_ID"
    --issuer "$HEARTH_NOTARY_ISSUER"
  )
else
  echo "Set HEARTH_NOTARY_PROFILE, or all of HEARTH_NOTARY_KEY, HEARTH_NOTARY_KEY_ID, HEARTH_NOTARY_ISSUER." >&2
  exit 2
fi

PLIST="Sources/HearthMonitor/Resources/Info.plist"
ENTITLEMENTS="Sources/HearthMonitor/Resources/HearthMonitor.entitlements"
VERSION="${HEARTH_MONITOR_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")}"
APP="dist/Hearth Monitor.app"
ZIP="dist/Hearth-Monitor-$VERSION.zip"

./scripts/package-monitor-app.sh

echo "Signing Hearth Monitor with Hardened Runtime and App Sandbox..."
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
  --entitlements "$ENTITLEMENTS" "$APP/Contents/MacOS/HearthMonitor"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
  --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --strict --verbose=2 "$APP"
lipo "$APP/Contents/MacOS/HearthMonitor" -verify_arch arm64 x86_64
./scripts/audit-monitor-boundary.sh

echo "Zipping for notarization..."
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Notarizing Hearth Monitor..."
xcrun notarytool submit "$ZIP" "${NOTARY_AUTH[@]}" --wait

echo "Stapling and verifying the app..."
xcrun stapler staple "$APP"
spctl --assess --type exec --verbose=4 "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Building and notarizing the DMG..."
DMG="$(
  HEARTH_MONITOR_VERSION="$VERSION" \
  HEARTH_MONITOR_SIGN_IDENTITY="$SIGN_IDENTITY" \
    ./scripts/make-monitor-dmg.sh
)"
xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

DMG_SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
ZIP_SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo
echo "Hearth Monitor public release artifacts:"
echo "  $DMG"
echo "    sha256: $DMG_SHA"
echo "  $ZIP"
echo "    sha256: $ZIP_SHA"
echo "Version: $VERSION"
