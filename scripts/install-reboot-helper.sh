#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# EXPERIMENTAL: install the hearth-reboot-helper root daemon, the
# least-privilege split for reboot-on-wedge. The helper is a tiny root
# LaunchDaemon whose entire API is "reboot, if you are the configured uid and
# not too often", offered on a root-owned unix socket. With it installed, a
# NON-root headless Hearth (rebootViaHelper: true in its config) keeps the full
# recovery ladder without the supervisor itself holding root.
#
# Run with sudo from a checkout:
#   sudo ./scripts/install-reboot-helper.sh
#
# The allowed uid defaults to the user invoking sudo; override with
# HEARTH_HELPER_UID. Remove with scripts/uninstall-reboot-helper.sh.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
ALLOWED_UID="${HEARTH_HELPER_UID:-${SUDO_UID:-}}"
[ -n "$ALLOWED_UID" ] || { echo "could not determine the allowed uid; set HEARTH_HELPER_UID"; exit 1; }
[ "$ALLOWED_UID" != "0" ] || { echo "the allowed uid must not be root; the point is an unprivileged client"; exit 1; }

cd "$(dirname "$0")/.."

echo "Building hearth-reboot-helper (release)..."
swift build -c release --product hearth-reboot-helper >/dev/null

LABEL="com.hearth.reboot-helper"
BINARY="/Library/PrivilegedHelperTools/${LABEL}"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"

mkdir -p /Library/PrivilegedHelperTools
install -m 755 -o root -g wheel ".build/release/hearth-reboot-helper" "$BINARY"

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
echo "Set \"rebootViaHelper\": true in the headless Hearth's config; its"
echo "recovery reboots now go through the helper instead of requiring root."
echo "The helper logs to /var/log/hearth-reboot-helper.log."
