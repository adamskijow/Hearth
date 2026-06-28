#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Install Hearth as a pre login root LaunchDaemon, running in headless mode so it
# supervises the runner before anyone logs in. This MODIFIES YOUR SYSTEM (writes
# to /usr/local/bin, /etc, and /Library/LaunchDaemons) and must be run with sudo.
# Read it before running.
#
# Usage:  sudo ./scripts/install-daemon.sh [path-to-Hearth-binary]
set -euo pipefail

cd "$(dirname "$0")/.."

if [ "$(id -u)" != "0" ]; then
  echo "Run with sudo: sudo ./scripts/install-daemon.sh" >&2
  exit 1
fi

BIN="${1:-.build/release/Hearth}"
if [ ! -x "$BIN" ]; then
  echo "No Hearth binary at $BIN. Run 'swift build -c release' first, or pass the path." >&2
  exit 1
fi

echo "Installing the binary to /usr/local/bin/hearth ..."
install -d -m 755 /usr/local/bin
install -m 755 "$BIN" /usr/local/bin/hearth

echo "Preparing /etc/hearth ..."
install -d -m 755 /etc/hearth
if [ ! -f /etc/hearth/config.json ]; then
  install -m 644 deploy/config.example.json /etc/hearth/config.json
  echo "Wrote /etc/hearth/config.json from the example."
  echo "EDIT IT (set your tokens and runner path) before relying on it."
fi

echo "Installing the LaunchDaemon ..."
install -m 644 deploy/com.hearth.daemon.plist /Library/LaunchDaemons/com.hearth.daemon.plist
chown root:wheel /Library/LaunchDaemons/com.hearth.daemon.plist

launchctl bootout system/com.hearth.daemon 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/com.hearth.daemon.plist

echo
echo "Installed. After editing /etc/hearth/config.json, apply it with:"
echo "  sudo launchctl kickstart -k system/com.hearth.daemon"
echo "Logs: /var/log/hearth.out.log and /var/log/hearth.err.log"
