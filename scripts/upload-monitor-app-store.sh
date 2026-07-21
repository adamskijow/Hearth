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

ALTOOL="${HEARTH_ALTOOL:-$(xcrun --find altool)}"
if ! "$ALTOOL" --help >/dev/null 2>&1; then
  # Xcode 26 can ship a Transporter-dependent shim at Developer/usr/bin/altool
  # even when the self-contained ContentDelivery implementation is present.
  # Prefer the shim when it works, but fall back to Apple's bundled binary.
  BUNDLED_ALTOOL="$DEVELOPER_DIR/../SharedFrameworks/ContentDelivery.framework/Versions/A/Resources/altool"
  if [ ! -x "$BUNDLED_ALTOOL" ]; then
    echo "Apple's altool is unavailable at $ALTOOL and $BUNDLED_ALTOOL." >&2
    exit 2
  fi
  ALTOOL="$BUNDLED_ALTOOL"
fi

AUTH=(
  --api-key "$HEARTH_ASC_KEY_ID"
  --api-issuer "$HEARTH_ASC_ISSUER"
  --p8-file-path "$HEARTH_ASC_KEY"
)

echo "Validating $PKG with App Store Connect..."
"$ALTOOL" --validate-app "$PKG" "${AUTH[@]}" --output-format json

if [ "${HEARTH_ASC_VALIDATE_ONLY:-0}" = "1" ]; then
  echo "Validation passed. Upload skipped because HEARTH_ASC_VALIDATE_ONLY=1."
  exit 0
fi

echo "Uploading $PKG to App Store Connect..."
"$ALTOOL" --upload-package "$PKG" "${AUTH[@]}" \
  --wait --show-progress --output-format json

echo "App Store Connect accepted Hearth Monitor $VERSION ($BUILD)."
