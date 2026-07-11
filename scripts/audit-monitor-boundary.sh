#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Mechanical guard for the product boundary. A green App Store build must not
# silently acquire the process, privilege, daemon, or package-manager powers of
# full Hearth as features are added.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="dist/Hearth Monitor.app"
SOURCES=("Sources/HearthMonitor" "Sources/HearthMonitorCore")

if rg -n \
  'import[[:space:]]+HearthSpawn|FoundationProcessController|RunnerStateStore|killpg\(|posix_spawn\(|SMAppService\.daemon|AuthorizationServices|brew upgrade|/Library/LaunchDaemons' \
  "${SOURCES[@]}"; then
  echo "Hearth Monitor boundary audit failed: forbidden full-product capability found."
  exit 1
fi

# The optional full-Hearth bridge is intentionally status-only. Deep runner
# probes need POST, so scope this guard to the bridge files rather than banning
# POST from the whole companion.
if rg -n \
  'url\(path:[[:space:]]*"/(start|stop|restart)"|httpMethod[[:space:]]*=[[:space:]]*"POST"' \
  Sources/HearthMonitor/FullHearth*.swift; then
  echo "Hearth Monitor boundary audit failed: full-Hearth bridge gained a control command."
  exit 1
fi

if rg -n 'public[[:space:]]+var[[:space:]]+(token|secret|bearer)[[:space:]]*:' Sources/HearthMonitorCore; then
  echo "Hearth Monitor boundary audit failed: a bearer secret entered Codable monitor state."
  exit 1
fi

test -x "$APP/Contents/MacOS/HearthMonitor"
lipo "$APP/Contents/MacOS/HearthMonitor" -verify_arch arm64 x86_64
test "$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")" = \
  "com.hearth.HearthMonitor"
test "$(plutil -extract LSApplicationCategoryType raw "$APP/Contents/Info.plist")" = \
  "public.app-category.utilities"

PRIVACY="$APP/Contents/Resources/PrivacyInfo.xcprivacy"
plutil -lint "$PRIVACY" >/dev/null
test "$(plutil -extract NSPrivacyTracking raw "$PRIVACY")" = "false"
test "$(plutil -extract NSPrivacyTrackingDomains json -o - "$PRIVACY")" = "[]"
test "$(plutil -extract NSPrivacyCollectedDataTypes json -o - "$PRIVACY")" = "[]"

ENTITLEMENTS="$(mktemp)"
trap 'rm -f "$ENTITLEMENTS"' EXIT
codesign -d --entitlements :- "$APP" >"$ENTITLEMENTS" 2>/dev/null
test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$ENTITLEMENTS")" = "true"
test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.client' "$ENTITLEMENTS")" = "true"

if plutil -p "$ENTITLEMENTS" | rg -q \
  'temporary-exception|disable-library-validation|allow-unsigned-executable-memory|keychain-access-groups|application-groups'; then
  echo "Hearth Monitor boundary audit failed: unsafe sandbox exception found."
  exit 1
fi

echo "Hearth Monitor boundary audit passed."
