#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Remove the Hearth LaunchDaemon and binary installed by install-daemon.sh.
# Run with sudo. Leaves /etc/hearth/config.json in place.
set -euo pipefail

if [ "$(id -u)" != "0" ]; then
  echo "Run with sudo: sudo ./scripts/uninstall-daemon.sh" >&2
  exit 1
fi

launchctl bootout system/com.hearth.daemon 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.hearth.daemon.plist
rm -f /usr/local/bin/hearth

echo "Removed the daemon and /usr/local/bin/hearth."
echo "Left /etc/hearth/config.json in place; delete it by hand if you want it gone."
