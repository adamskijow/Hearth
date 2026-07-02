#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Remove the experimental hearth-reboot-helper root daemon: the LaunchDaemon,
# the binary, and its socket. Run with sudo.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

LABEL="com.hearth.reboot-helper"
launchctl bootout "system/${LABEL}" 2>/dev/null || true
rm -f "/Library/LaunchDaemons/${LABEL}.plist"
rm -f "/Library/PrivilegedHelperTools/${LABEL}"
rm -f /var/run/hearth-reboot.sock

echo "Removed ${LABEL}. Turn off rebootViaHelper in the Hearth config."
