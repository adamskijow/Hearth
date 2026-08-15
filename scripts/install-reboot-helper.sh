#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# EXPERIMENTAL: install the hearth-reboot-helper root daemon, the
# least-privilege split for reboot-on-wedge. The helper is a tiny root
# LaunchDaemon whose entire API is "reboot, if you are the configured uid, the
# live client matches the installed Hearth signature, and not too often",
# offered on a root-owned unix socket. With it installed, a
# NON-root headless Hearth (rebootViaHelper: true in its config) keeps the full
# recovery ladder without the supervisor itself holding root.
#
# Run with sudo from a checkout:
#   sudo ./scripts/install-reboot-helper.sh
#
# The allowed uid defaults to the user invoking sudo; override with
# HEARTH_HELPER_UID. The allowed client defaults to the Developer ID signed
# /Applications/Hearth.app binary; override with HEARTH_HELPER_CLIENT. Ad-hoc or
# non-hardened builds are refused because UID-only authorization is not a useful
# boundary between apps in one macOS login. Remove with the uninstall script.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
ALLOWED_UID="${HEARTH_HELPER_UID:-${SUDO_UID:-}}"
[ -n "$ALLOWED_UID" ] || { echo "could not determine the allowed uid; set HEARTH_HELPER_UID"; exit 1; }
[[ "$ALLOWED_UID" =~ ^[0-9]+$ ]] || { echo "the allowed uid must be numeric"; exit 1; }
[ "$ALLOWED_UID" != "0" ] || { echo "the allowed uid must not be root; the point is an unprivileged client"; exit 1; }

cd "$(dirname "$0")/.."

echo "Building hearth-reboot-helper (release)..."
swift build -c release --product hearth-reboot-helper >/dev/null

LABEL="com.hearth.reboot-helper"
BINARY="/Library/PrivilegedHelperTools/${LABEL}"
REQUIREMENT_FILE="/Library/PrivilegedHelperTools/${LABEL}.requirement"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
CLIENT_INPUT="${HEARTH_HELPER_CLIENT:-/Applications/Hearth.app/Contents/MacOS/Hearth}"

[ -x "$CLIENT_INPUT" ] || {
  echo "no executable Hearth client at $CLIENT_INPUT" >&2
  echo "Install the signed GitHub release, or set HEARTH_HELPER_CLIENT to its executable." >&2
  exit 1
}
CLIENT_DIR="$(cd "$(dirname "$CLIENT_INPUT")" && pwd -P)"
CLIENT_PATH="$CLIENT_DIR/$(basename "$CLIENT_INPUT")"
case "$CLIENT_PATH" in
  *['<>&']*) echo "the client path contains characters unsafe for a launchd plist" >&2; exit 1 ;;
esac

codesign --verify --strict "$CLIENT_PATH"
SIGNING_INFO="$(codesign -dvvv "$CLIENT_PATH" 2>&1)"
if printf '%s\n' "$SIGNING_INFO" | grep -q 'Signature=adhoc'; then
  echo "the reboot helper refuses an ad-hoc signed client; use a Developer ID release" >&2
  exit 1
fi
if ! printf '%s\n' "$SIGNING_INFO" | grep -q 'flags=.*runtime'; then
  echo "the reboot helper requires a Hardened Runtime client" >&2
  exit 1
fi
REQUIREMENT="$(codesign -d -r- "$CLIENT_PATH" 2>&1 | sed -n 's/^designated => //p')"
[ -n "$REQUIREMENT" ] || { echo "could not read the client designated requirement" >&2; exit 1; }
if ! printf '%s\n' "$REQUIREMENT" | grep -q 'anchor apple'; then
  echo "the reboot helper requires an Apple-anchored Developer ID signature" >&2
  exit 1
fi

mkdir -p /Library/PrivilegedHelperTools
install -m 755 -o root -g wheel ".build/release/hearth-reboot-helper" "$BINARY"
REQUIREMENT_TMP="$(mktemp)"
trap 'rm -f "$REQUIREMENT_TMP"' EXIT
printf '%s\n' "$REQUIREMENT" > "$REQUIREMENT_TMP"
install -m 600 -o root -g wheel "$REQUIREMENT_TMP" "$REQUIREMENT_FILE"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${BINARY}</string>
		<string>${ALLOWED_UID}</string>
		<string>${CLIENT_PATH}</string>
		<string>${REQUIREMENT_FILE}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardErrorPath</key>
	<string>/var/log/hearth-reboot-helper.log</string>
</dict>
</plist>
PLIST
chmod 644 "$PLIST"
chown root:wheel "$PLIST"

launchctl bootout "system/${LABEL}" 2>/dev/null || true
launchctl bootstrap system "$PLIST"

echo "Installed ${LABEL} (allowed uid ${ALLOWED_UID})."
echo "Authorized client: ${CLIENT_PATH} (live audit token + Developer ID requirement)."
echo "Set \"rebootViaHelper\": true in the headless Hearth's config; its"
echo "recovery reboots now go through the helper instead of requiring root."
echo "The helper logs to /var/log/hearth-reboot-helper.log."
