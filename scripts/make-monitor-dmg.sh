#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Build a drag-to-install DMG from dist/Hearth Monitor.app. When
# HEARTH_MONITOR_SIGN_IDENTITY (or HEARTH_SIGN_IDENTITY) is set, sign the disk
# image so release-monitor.sh can notarize and staple it.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="dist/Hearth Monitor.app"
[ -d "$APP" ] || {
  echo "No $APP. Run scripts/package-monitor-app.sh first." >&2
  exit 1
}

PLIST="Sources/HearthMonitor/Resources/Info.plist"
VERSION="${HEARTH_MONITOR_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")}"
DMG="dist/Hearth-Monitor-$VERSION.dmg"
VOLUME="Hearth Monitor"
SIGN_IDENTITY="${HEARTH_MONITOR_SIGN_IDENTITY:-${HEARTH_SIGN_IDENTITY:-}}"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Hearth Monitor.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "$VOLUME" -srcfolder "$STAGE" \
  -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

if [ -n "$SIGN_IDENTITY" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi

echo "$DMG"
