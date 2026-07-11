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

search_sources() {
  local pattern="$1"
  shift
  if command -v rg >/dev/null 2>&1; then
    rg -n "$pattern" "$@"
  else
    grep -EnR "$pattern" "$@"
  fi
}

search_stdin() {
  local pattern="$1"
  if command -v rg >/dev/null 2>&1; then
    rg -q "$pattern"
  else
    grep -Eq "$pattern"
  fi
}

if search_sources \
  'import[[:space:]]+HearthSpawn|FoundationProcessController|RunnerStateStore|killpg\(|posix_spawn\(|SMAppService\.daemon|AuthorizationServices|brew upgrade|/Library/LaunchDaemons' \
  "${SOURCES[@]}"; then
  echo "Hearth Monitor boundary audit failed: forbidden full-product capability found."
  exit 1
fi

# The optional full-Hearth bridge is intentionally status-only. Deep runner
# probes need POST, so scope this guard to the bridge files rather than banning
# POST from the whole companion.
if search_sources \
  'url\(path:[[:space:]]*"/(start|stop|restart)"|httpMethod[[:space:]]*=[[:space:]]*"POST"' \
  Sources/HearthMonitor/FullHearth*.swift; then
  echo "Hearth Monitor boundary audit failed: full-Hearth bridge gained a control command."
  exit 1
fi

if search_sources 'public[[:space:]]+var[[:space:]]+(token|secret|bearer)[[:space:]]*:' Sources/HearthMonitorCore; then
  echo "Hearth Monitor boundary audit failed: a bearer secret entered Codable monitor state."
  exit 1
fi

if search_sources 'import[[:space:]]+FoundationModels' "${SOURCES[@]}" \
  | grep -Ev '^Sources/HearthMonitor/AppleFoundationModelProbe\.swift:'; then
  echo "Hearth Monitor boundary audit failed: Foundation Models escaped its single adapter file."
  exit 1
fi

test -x "$APP/Contents/MacOS/HearthMonitor"
lipo "$APP/Contents/MacOS/HearthMonitor" -verify_arch arm64 x86_64
if ! otool -L "$APP/Contents/MacOS/HearthMonitor" \
  | search_stdin 'FoundationModels\.framework.*weak'; then
  echo "Hearth Monitor boundary audit failed: shipping binary lacks weak-linked Foundation Models."
  exit 1
fi
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

if plutil -p "$ENTITLEMENTS" | search_stdin \
  'temporary-exception|disable-library-validation|allow-unsigned-executable-memory|keychain-access-groups|application-groups'; then
  echo "Hearth Monitor boundary audit failed: unsafe sandbox exception found."
  exit 1
fi

echo "Hearth Monitor boundary audit passed."
