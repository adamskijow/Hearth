#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Assemble a locally testable, sandboxed Hearth Monitor.app. This is a packaging
# proof, not an App Store upload: a store submission additionally needs an Apple
# Distribution identity, an App Store provisioning profile, and Transporter (or
# equivalent App Store Connect tooling) from a full Xcode installation.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Hearth Monitor"
DIST="dist"
APP="$DIST/$APP_NAME.app"
PLIST="Sources/HearthMonitor/Resources/Info.plist"
ENTITLEMENTS="Sources/HearthMonitor/Resources/HearthMonitor.entitlements"
PRIVACY="Sources/HearthMonitor/Resources/PrivacyInfo.xcprivacy"
# This package has no remote dependencies or plugins. Disable SwiftPM's build
# sandbox consistently so the script also works when invoked from a managed CI
# sandbox; the assembled app is still signed and exercised with its real App
# Sandbox entitlements below.
SWIFT_FLAGS=(--disable-sandbox)

# A Command Line Tools-only installation can briefly contain a newer compiler
# beside a newer SDK whose Swift interfaces were emitted by the prior point
# release (for example compiler 6.3.3 and SDK interfaces from 6.3.2). The stable
# macOS 15.4 SDK is still present and supports Hearth's macOS 14 deployment
# target. Select it only for that CLT-only layout; full Xcode and CI keep their
# normal SDK selection. SwiftPM's nested sandbox is also incompatible with the
# managed execution sandbox used by local automation, so disable only that
# redundant inner layer while the signed app's real App Sandbox remains active.
if [[ "$(xcode-select -p 2>/dev/null || true)" == "/Library/Developer/CommandLineTools" \
   && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/hearth-clang-cache"
  export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/hearth-swiftpm-cache"
elif [[ "$(xcode-select -p 2>/dev/null || true)" == "/Library/Developer/CommandLineTools" \
   && -d "/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk" ]]; then
  export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
  export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/hearth-clang-cache"
  export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/hearth-swiftpm-cache"
fi

# Monitor has no architecture-specific process code and is useful as a remote
# observer from either an Intel or Apple-silicon Mac. Keep the App Store product
# universal even though full Hearth's primary managed-runner use case is Apple
# silicon.
SWIFT_FLAGS+=(--arch arm64 --arch x86_64)

plutil -lint "$PLIST" >/dev/null
plutil -lint "$ENTITLEMENTS" >/dev/null
plutil -lint "$PRIVACY" >/dev/null
swift build "${SWIFT_FLAGS[@]}" -c release --product HearthMonitor
BIN_PATH="$(swift build "${SWIFT_FLAGS[@]}" -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/HearthMonitor" "$APP/Contents/MacOS/HearthMonitor"
cp "$PLIST" "$APP/Contents/Info.plist"
cp "assets/MonitorIcon.icns" "$APP/Contents/Resources/MonitorIcon.icns"
cp "$PRIVACY" "$APP/Contents/Resources/PrivacyInfo.xcprivacy"

# Ad-hoc signing activates the sandbox for local validation. App Store signing
# replaces this identity while retaining the exact entitlement boundary.
codesign --force --options runtime --sign - --entitlements "$ENTITLEMENTS" \
  "$APP/Contents/MacOS/HearthMonitor"
codesign --force --options runtime --sign - --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --strict --verbose=2 "$APP"
lipo "$APP/Contents/MacOS/HearthMonitor" -verify_arch arm64 x86_64

# Optional because a CI login keychain may be locked or absent. Local/App Store
# archive validation can exercise the signed app's private Keychain boundary with
# no retained credential.
if [[ "${HEARTH_MONITOR_KEYCHAIN_SELF_TEST:-0}" == "1" ]]; then
  "$APP/Contents/MacOS/HearthMonitor" --self-test-keychain
fi

echo "Built sandboxed app: $APP"
