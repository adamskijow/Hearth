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
TIMEOUT="${HEARTH_MONITOR_DOGFOOD_TIMEOUT:-75}"

if [[ ! -x "$APP/Contents/MacOS/HearthMonitor" ]]; then
  echo "Hearth Monitor dogfood build is missing or not executable: $APP" >&2
  exit 2
fi
if [[ ! "$INTERVAL" =~ ^[0-9]+$ ]] || (( INTERVAL < 300 )); then
  echo "HEARTH_MONITOR_DOGFOOD_INTERVAL must be at least 300 seconds." >&2
  exit 2
fi
if [[ ! "$TIMEOUT" =~ ^[0-9]+$ ]] || (( TIMEOUT < 1 || TIMEOUT > 300 )); then
  echo "HEARTH_MONITOR_DOGFOOD_TIMEOUT must be between 1 and 300 seconds." >&2
  exit 2
fi

LOG_DIRECTORY="$(dirname "$LOG")"
if [[ ! -d "$LOG_DIRECTORY" ]]; then
  mkdir -p "$LOG_DIRECTORY"
  chmod 700 "$LOG_DIRECTORY"
fi
if [[ ! -e "$LOG" ]]; then
  printf 'timestamp_utc\texit_status\tresult\n' >"$LOG"
fi
chmod 600 "$LOG"

record_once() {
  local timestamp output status capture timeout_marker pid watchdog
  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  capture="$(mktemp "${TMPDIR:-/tmp}/hearth-monitor-dogfood.XXXXXX")"
  timeout_marker="${capture}.timed-out"
  "$APP/Contents/MacOS/HearthMonitor" --self-test-apple-model >"$capture" 2>&1 &
  pid=$!
  (
    sleep "$TIMEOUT"
    if kill -0 "$pid" 2>/dev/null; then
      touch "$timeout_marker"
      kill "$pid" 2>/dev/null || true
      sleep 2
      kill -9 "$pid" 2>/dev/null || true
    fi
  ) >/dev/null 2>&1 &
  watchdog=$!
  wait "$pid"
  status=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  output="$(<"$capture")"
  if [[ -e "$timeout_marker" ]]; then
    status=124
    output="Apple model self-test exceeded the ${TIMEOUT}-second process timeout and was terminated."
  fi
  rm -f "$capture" "$timeout_marker"
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
