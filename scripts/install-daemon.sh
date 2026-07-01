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
install -d -m 700 /etc/hearth
if [ ! -f /etc/hearth/config.json ]; then
  install -m 600 deploy/config.example.json /etc/hearth/config.json
  echo "Wrote /etc/hearth/config.json from the example."
  echo "EDIT IT (set your tokens and runner path) before relying on it."
fi
# The config holds the control token (and ntfy topic), so keep it root-only even if
# it already existed from an earlier install.
chmod 600 /etc/hearth/config.json

echo "Preparing daemon logs ..."
touch /var/log/hearth.out.log /var/log/hearth.err.log
chown root:wheel /var/log/hearth.out.log /var/log/hearth.err.log
chmod 600 /var/log/hearth.out.log /var/log/hearth.err.log

echo "Installing the LaunchDaemon ..."
install -m 644 deploy/com.hearth.daemon.plist /Library/LaunchDaemons/com.hearth.daemon.plist
chown root:wheel /Library/LaunchDaemons/com.hearth.daemon.plist

# Rotate the daemon's own /var/log output so it cannot grow unbounded.
echo "Installing newsyslog rotation for the daemon logs ..."
install -d -m 755 /etc/newsyslog.d
install -m 644 deploy/hearth.newsyslog.conf /etc/newsyslog.d/hearth.conf

# Stop any previously loaded daemon before the preflight. That prevents an old
# Hearth-owned runner from masking the new daemon's first-start behavior.
launchctl bootout system/com.hearth.daemon 2>/dev/null || true

echo "Checking the daemon config ..."
doctor_status=0
doctor_output="$(/usr/local/bin/hearth doctor-daemon 2>&1)" || doctor_status=$?
printf "%s\n" "$doctor_output"

doctor_has_warnings=0
if printf "%s\n" "$doctor_output" | grep -q "^  WARN"; then
  doctor_has_warnings=1
fi

echo
if [ "$doctor_status" != "0" ]; then
  echo "Installed but not started. Fix the doctor errors above, then run:"
  echo "  sudo hearth doctor-daemon"
  echo "  sudo launchctl bootstrap system /Library/LaunchDaemons/com.hearth.daemon.plist"
  echo "For later config changes after the daemon is loaded, use:"
  echo "  sudo launchctl kickstart -k system/com.hearth.daemon"
  echo "Logs: /var/log/hearth.out.log and /var/log/hearth.err.log"
  exit 0
fi

launchctl bootstrap system /Library/LaunchDaemons/com.hearth.daemon.plist

if [ "$doctor_has_warnings" = "1" ]; then
  echo "Started with the doctor warnings shown above. Review them; if you change config later, run:"
  echo "  sudo hearth doctor-daemon"
  echo "  sudo launchctl kickstart -k system/com.hearth.daemon"
  echo "Logs: /var/log/hearth.out.log and /var/log/hearth.err.log"
  exit 0
fi

echo "Installed and started. After editing /etc/hearth/config.json, apply it with:"
echo "  sudo hearth doctor-daemon"
echo "  sudo launchctl kickstart -k system/com.hearth.daemon"
echo "Logs: /var/log/hearth.out.log and /var/log/hearth.err.log"
