#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Install or remove the per-user, token-free Hearth Monitor dogfood scheduler.
set -euo pipefail

LABEL="com.hearth.monitor.dogfood"
DOMAIN="gui/$(id -u)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT="$ROOT/scripts/dogfood-monitor-agent.sh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIRECTORY="$HOME/Library/Logs/Hearth Monitor"
RESULT_LOG="$LOG_DIRECTORY/dogfood.tsv"
LAUNCH_LOG="$LOG_DIRECTORY/dogfood-launchd.log"

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Removed the Hearth Monitor dogfood LaunchAgent. Existing logs were preserved at $LOG_DIRECTORY."
  exit 0
fi

if [[ -n "${1:-}" ]]; then
  echo "Usage: $0 [--uninstall]" >&2
  exit 2
fi

mkdir -p "$(dirname "$PLIST")" "$LOG_DIRECTORY"
chmod 700 "$LOG_DIRECTORY"

temporary_plist="$(mktemp "${TMPDIR:-/tmp}/hearth-monitor-dogfood-plist.XXXXXX")"
trap 'rm -f "$temporary_plist"' EXIT

plutil -create xml1 "$temporary_plist"
plutil -insert Label -string "$LABEL" "$temporary_plist"
plutil -insert ProgramArguments -array "$temporary_plist"
plutil -insert ProgramArguments.0 -string /bin/zsh "$temporary_plist"
plutil -insert ProgramArguments.1 -string "$AGENT" "$temporary_plist"
plutil -insert RunAtLoad -bool true "$temporary_plist"
plutil -insert StartInterval -integer 900 "$temporary_plist"
plutil -insert ProcessType -string Background "$temporary_plist"
plutil -insert LimitLoadToSessionType -string Aqua "$temporary_plist"
plutil -insert EnvironmentVariables -dictionary "$temporary_plist"
plutil -insert EnvironmentVariables.HEARTH_MONITOR_DOGFOOD_APP -string "/Applications/Hearth Monitor.app" "$temporary_plist"
plutil -insert EnvironmentVariables.HEARTH_MONITOR_DOGFOOD_LOG -string "$RESULT_LOG" "$temporary_plist"
plutil -insert EnvironmentVariables.HEARTH_MONITOR_DOGFOOD_TIMEOUT -string 75 "$temporary_plist"
plutil -insert StandardOutPath -string "$LAUNCH_LOG" "$temporary_plist"
plutil -insert StandardErrorPath -string "$LAUNCH_LOG" "$temporary_plist"

plutil -lint "$temporary_plist" >/dev/null
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
install -m 600 "$temporary_plist" "$PLIST"
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl enable "$DOMAIN/$LABEL"
launchctl kickstart -k "$DOMAIN/$LABEL"

echo "Installed the Hearth Monitor dogfood LaunchAgent."
echo "Canary results: $RESULT_LOG"
echo "Scheduler diagnostics: $LAUNCH_LOG"
