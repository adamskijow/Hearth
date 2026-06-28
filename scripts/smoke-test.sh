#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# A local, end to end smoke test of the running agent against the fake runner.
# It verifies the acceptance behavior without needing Ollama: the agent starts
# and owns the child, holds the sleep preventing power assertion, restarts the
# child when it is killed externally, and releases the assertion and kills the
# child on a clean shutdown.
#
# This launches the real menubar agent, so it needs a logged in desktop session
# (a window server). It is not meant for headless CI; CI runs the unit tests.
set -euo pipefail

cd "$(dirname "$0")/.."

PORT="${HEARTH_SMOKE_PORT:-11899}"
WORKDIR="$(mktemp -d)"
CONFIG="$WORKDIR/config.json"
RUNNER="$PWD/scripts/fake-runner.py"
BIN=".build/debug/Hearth"

cleanup() {
  [ -n "${HEARTH_PID:-}" ] && kill -TERM "$HEARTH_PID" 2>/dev/null || true
  sleep 1
  pkill -f "fake-runner.py" 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; exit 1; }

# Reads the whole pmset stream (no `grep -q`, which would close the pipe early
# and trip pipefail via SIGPIPE). Returns 0 if Hearth holds an assertion.
assertion_held() { pmset -g assertions | grep -i hearth >/dev/null 2>&1; }

echo "Building..."
swift build >/dev/null

cat > "$CONFIG" <<JSON
{
  "ollamaBinaryPath": "$RUNNER",
  "host": "127.0.0.1",
  "port": $PORT,
  "probeIntervalSeconds": 1,
  "startupGraceSeconds": 5,
  "startupProbeIntervalSeconds": 0.5,
  "initialBackoffSeconds": 1,
  "localNotifications": false
}
JSON

echo "Launching Hearth (HEARTH_CONFIG=$CONFIG)..."
HEARTH_CONFIG="$CONFIG" "$BIN" >"$WORKDIR/hearth.log" 2>&1 &
HEARTH_PID=$!
sleep 4

echo "1. Owns the child and is serving"
CHILD="$(pgrep -f 'fake-runner.py' || true)"
[ -n "$CHILD" ] || fail "no child spawned"
curl -fs --max-time 2 "http://127.0.0.1:$PORT/api/version" >/dev/null || fail "runner not serving"
pass "child $CHILD serving on $PORT"

echo "2. Holds the power assertion"
assertion_held || fail "power assertion not held"
pass "PreventUserIdleSystemSleep held"

echo "3. Restarts the child when killed externally"
kill -9 "$CHILD"
RESTARTED=""
for _ in $(seq 1 8); do
  sleep 1
  NEW="$(pgrep -f 'fake-runner.py' || true)"
  if [ -n "$NEW" ] && [ "$NEW" != "$CHILD" ]; then RESTARTED="$NEW"; break; fi
done
[ -n "$RESTARTED" ] || fail "child was not restarted"
curl -fs --max-time 2 "http://127.0.0.1:$PORT/api/version" >/dev/null || fail "not serving after restart"
pass "restarted as $RESTARTED and serving"

echo "4. Clean shutdown releases the assertion and kills the child"
kill -TERM "$HEARTH_PID"; HEARTH_PID=""
sleep 2
if pgrep -f 'fake-runner.py' >/dev/null; then fail "child was orphaned"; fi
if assertion_held; then fail "assertion still held"; fi
pass "child stopped and assertion released"

echo
echo "All smoke checks passed."
