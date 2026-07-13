#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Validate and upload a distribution-signed Hearth Monitor package with an
# App Store Connect API key. The private key is read from its operator-supplied
# path and is never copied into the repository or an app bundle.
set -euo pipefail

cd "$(dirname "$0")/.."

: "${HEARTH_ASC_KEY:?Set HEARTH_ASC_KEY to the AuthKey_XXXX.p8 private key path}"
: "${HEARTH_ASC_KEY_ID:?Set HEARTH_ASC_KEY_ID to the App Store Connect key ID}"
: "${HEARTH_ASC_ISSUER:?Set HEARTH_ASC_ISSUER to the App Store Connect issuer ID}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

PLIST="Sources/HearthMonitor/Resources/Info.plist"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$PLIST")"
BUILD="$(plutil -extract CFBundleVersion raw "$PLIST")"
PKG="${HEARTH_MONITOR_PKG:-dist/Hearth-Monitor-$VERSION-$BUILD.pkg}"

test -f "$HEARTH_ASC_KEY"
test -f "$PKG"
xcrun --find altool >/dev/null

AUTH=(
  --api-key "$HEARTH_ASC_KEY_ID"
  --api-issuer "$HEARTH_ASC_ISSUER"
  --p8-file-path "$HEARTH_ASC_KEY"
)

echo "Validating $PKG with App Store Connect..."
xcrun altool --validate-app "$PKG" "${AUTH[@]}" --output-format json

if [ "${HEARTH_ASC_VALIDATE_ONLY:-0}" = "1" ]; then
  echo "Validation passed. Upload skipped because HEARTH_ASC_VALIDATE_ONLY=1."
  exit 0
fi

echo "Uploading $PKG to App Store Connect..."
xcrun altool --upload-package "$PKG" "${AUTH[@]}" \
  --wait --show-progress --output-format json

echo "App Store Connect accepted Hearth Monitor $VERSION ($BUILD)."
