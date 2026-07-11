#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Build a Mac App Store Connect installer package for Hearth Monitor. Account
# identities and the explicit App Store provisioning profile are supplied by the
# release operator and never stored in the repository.
set -euo pipefail

cd "$(dirname "$0")/.."

: "${HEARTH_MONITOR_APP_IDENTITY:?Set HEARTH_MONITOR_APP_IDENTITY to a Mac App Distribution or Apple Distribution identity}"
: "${HEARTH_MONITOR_INSTALLER_IDENTITY:?Set HEARTH_MONITOR_INSTALLER_IDENTITY to a Mac Installer Distribution identity}"
: "${HEARTH_MONITOR_PROFILE:?Set HEARTH_MONITOR_PROFILE to the Mac App Store Connect provisioning profile}"

APP="dist/Hearth Monitor.app"
PLIST="Sources/HearthMonitor/Resources/Info.plist"
ENTITLEMENTS="Sources/HearthMonitor/Resources/HearthMonitor.entitlements"
BUNDLE_ID="com.hearth.HearthMonitor"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$PLIST")"
BUILD="$(plutil -extract CFBundleVersion raw "$PLIST")"
PKG="dist/Hearth-Monitor-$VERSION-$BUILD.pkg"
PROFILE_PLIST="$(mktemp)"
SIGN_ENTITLEMENTS="$(mktemp)"
trap 'rm -f "$PROFILE_PLIST" "$SIGN_ENTITLEMENTS"' EXIT

test -f "$HEARTH_MONITOR_PROFILE"
security cms -D -i "$HEARTH_MONITOR_PROFILE" >"$PROFILE_PLIST"
PROFILE_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST")"
TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$PROFILE_PLIST")"
case "$PROFILE_APP_ID" in
  *."$BUNDLE_ID") ;;
  *)
    echo "Provisioning profile is for $PROFILE_APP_ID, not $BUNDLE_ID." >&2
    exit 2
    ;;
esac

cp "$ENTITLEMENTS" "$SIGN_ENTITLEMENTS"
/usr/libexec/PlistBuddy \
  -c "Add :com.apple.application-identifier string $PROFILE_APP_ID" \
  "$SIGN_ENTITLEMENTS"
/usr/libexec/PlistBuddy \
  -c "Add :com.apple.developer.team-identifier string $TEAM_ID" \
  "$SIGN_ENTITLEMENTS"

bash scripts/package-monitor-app.sh
cp "$HEARTH_MONITOR_PROFILE" "$APP/Contents/embedded.provisionprofile"

codesign --force --timestamp --sign "$HEARTH_MONITOR_APP_IDENTITY" \
  --entitlements "$SIGN_ENTITLEMENTS" "$APP/Contents/MacOS/HearthMonitor"
codesign --force --timestamp --sign "$HEARTH_MONITOR_APP_IDENTITY" \
  --entitlements "$SIGN_ENTITLEMENTS" "$APP"
codesign --verify --strict --verbose=4 "$APP"
bash scripts/audit-monitor-boundary.sh

rm -f "$PKG"
productbuild --component "$APP" /Applications \
  --sign "$HEARTH_MONITOR_INSTALLER_IDENTITY" "$PKG"
pkgutil --check-signature "$PKG"

echo "Built Mac App Store package: $PKG"
echo "Validate and upload it with Xcode Organizer, Transporter, or xcrun altool."
