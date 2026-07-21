#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# LaunchAgent entry point for unattended Hearth Monitor dogfooding. Keep the
# installed menu-bar app alive, then record one privacy-safe Apple model canary.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${HEARTH_MONITOR_DOGFOOD_APP:-/Applications/Hearth Monitor.app}"

if [[ ! -x "$APP/Contents/MacOS/HearthMonitor" ]]; then
  echo "Hearth Monitor dogfood build is missing or not executable: $APP" >&2
  exit 2
fi

# A StartInterval job is deliberately used instead of KeepAlive: the Monitor is
# a menu-bar app, while this helper should exit after each bounded canary. If the
# app was closed or crashed, launch it unobtrusively before collecting evidence.
if ! /usr/bin/pgrep -x HearthMonitor >/dev/null 2>&1; then
  /usr/bin/open -gj "$APP"
fi

exec "$ROOT/scripts/dogfood-monitor.sh"
