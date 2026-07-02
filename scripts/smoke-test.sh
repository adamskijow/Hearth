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
CTRL_PORT="${HEARTH_SMOKE_CTRL_PORT:-11935}"
CTRL_TOKEN="smoke-token-$$"
WORKDIR="$(mktemp -d)"
CONFIG="$WORKDIR/config.json"
RUNNER="$PWD/scripts/fake-runner.py"
BIN=".build/debug/Hearth"

STATE_FILE="$HOME/Library/Application Support/Hearth/runner-state.json"
cleanup() {
  [ -n "${HEARTH_PID:-}" ] && kill -TERM "$HEARTH_PID" 2>/dev/null || true
  sleep 1
  pkill -f "fake-runner.py" 2>/dev/null || true
  rm -rf "$WORKDIR"
  rm -f "$STATE_FILE"
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; exit 1; }

# Reads the whole pmset stream (no `grep -q`, which would close the pipe early
# and trip pipefail via SIGPIPE). Returns 0 if the given PID holds an assertion.
# Scoped to the test agent's pid, not a name match: a real Hearth instance (the
# login agent, say) legitimately holds its own assertion and must not make
# step 2 pass or step 5 fail on its behalf.
assertion_held_by() { pmset -g assertions | grep "pid $1(" >/dev/null 2>&1; }

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
  "localNotifications": false,
  "controlEnabled": true,
  "controlHost": "127.0.0.1",
  "controlPort": $CTRL_PORT,
  "controlToken": "$CTRL_TOKEN"
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
assertion_held_by "$HEARTH_PID" || fail "power assertion not held"
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

echo "4. Control endpoint (auth, status, remote restart)"
CODE=$(curl -s -o "$WORKDIR/status.json" -w '%{http_code}' --max-time 3 \
  -H "Authorization: Bearer $CTRL_TOKEN" "http://127.0.0.1:$CTRL_PORT/status" || true)
[ "$CODE" = "200" ] || fail "GET /status returned $CODE"
grep -q '"phase"' "$WORKDIR/status.json" || fail "status JSON missing phase"
UNAUTH=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$CTRL_PORT/status" || true)
[ "$UNAUTH" = "401" ] || fail "unauthenticated request returned $UNAUTH (expected 401)"
BEFORE="$(pgrep -f 'fake-runner.py' || true)"
RCODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 -X POST \
  -H "Authorization: Bearer $CTRL_TOKEN" "http://127.0.0.1:$CTRL_PORT/restart" || true)
[ "$RCODE" = "202" ] || fail "POST /restart returned $RCODE (expected 202)"
REMOTE_RESTARTED=""
for _ in $(seq 1 8); do
  sleep 1
  NOW="$(pgrep -f 'fake-runner.py' || true)"
  if [ -n "$NOW" ] && [ "$NOW" != "$BEFORE" ]; then REMOTE_RESTARTED="$NOW"; break; fi
done
[ -n "$REMOTE_RESTARTED" ] || fail "remote restart did not cycle the child"
pass "status 200, 401 without token, remote restart cycled the child"

echo "5. Clean shutdown releases the assertion and kills the child"
TERMED_PID="$HEARTH_PID"
kill -TERM "$HEARTH_PID"; HEARTH_PID=""
sleep 2
if pgrep -f 'fake-runner.py' >/dev/null; then fail "child was orphaned"; fi
if assertion_held_by "$TERMED_PID"; then fail "assertion still held"; fi
pass "child stopped and assertion released"

echo "6. A hard SIGKILL of Hearth orphans the child; the next launch sweeps it"
rm -f "$STATE_FILE"
HEARTH_CONFIG="$CONFIG" "$BIN" >"$WORKDIR/h-crash.log" 2>&1 &
HEARTH_PID=$!
sleep 4
ORPHAN="$(pgrep -f 'fake-runner.py' | head -1 || true)"
[ -n "$ORPHAN" ] || fail "no child before the simulated crash"
kill -9 "$HEARTH_PID"; HEARTH_PID=""   # hard kill: Hearth gets no chance to tear down
sleep 2
ps -p "$ORPHAN" -o pid= >/dev/null 2>&1 || fail "child did not survive the hard kill (cannot test recovery)"
HEARTH_CONFIG="$CONFIG" "$BIN" >"$WORKDIR/h-recover.log" 2>&1 &
HEARTH_PID=$!
sleep 4
if ps -p "$ORPHAN" -o pid= >/dev/null 2>&1; then fail "orphaned child $ORPHAN survived the next launch"; fi
pass "orphaned child $ORPHAN was swept on the next launch"
kill -TERM "$HEARTH_PID"; HEARTH_PID=""
sleep 1
pkill -f "fake-runner.py" 2>/dev/null || true

echo
echo "All smoke checks passed."
