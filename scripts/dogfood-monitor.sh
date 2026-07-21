#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Collect real, privacy-safe Foundation Models health evidence from the signed
# Hearth Monitor build. Output contains only time, exit status, and the existing
# self-test summary; the fixed prompt and generated response are never logged.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${HEARTH_MONITOR_DOGFOOD_APP:-/Applications/Hearth Monitor.app}"
LOG="${HEARTH_MONITOR_DOGFOOD_LOG:-$ROOT/.dogfood/hearth-monitor.tsv}"
INTERVAL="${HEARTH_MONITOR_DOGFOOD_INTERVAL:-900}"

if [[ ! -x "$APP/Contents/MacOS/HearthMonitor" ]]; then
  echo "Hearth Monitor dogfood build is missing or not executable: $APP" >&2
  exit 2
fi
if [[ ! "$INTERVAL" =~ ^[0-9]+$ ]] || (( INTERVAL < 300 )); then
  echo "HEARTH_MONITOR_DOGFOOD_INTERVAL must be at least 300 seconds." >&2
  exit 2
fi

mkdir -p "$(dirname "$LOG")"
chmod 700 "$(dirname "$LOG")"
if [[ ! -e "$LOG" ]]; then
  printf 'timestamp_utc\texit_status\tresult\n' >"$LOG"
fi
chmod 600 "$LOG"

record_once() {
  local timestamp output status
  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  output="$("$APP/Contents/MacOS/HearthMonitor" --self-test-apple-model 2>&1)"
  status=$?
  if [[ -z "$output" ]]; then
    if (( status > 128 )); then
      output="Apple model self-test terminated without output (signal $((status - 128)), exit $status)."
    else
      output="Apple model self-test exited with status $status and no diagnostic output."
    fi
  fi
  output="${output//$'\t'/ }"
  output="${output//$'\n'/ }"
  printf '%s\t%s\t%s\n' "$timestamp" "$status" "$output" >>"$LOG"
  return "$status"
}

if [[ "${1:-}" == "--loop" ]]; then
  while true; do
    record_once || true
    sleep "$INTERVAL"
  done
fi

record_once
