#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Integration gate: drive the REAL Hearth agent against a REAL `ollama serve`
# (not the fake runner) and prove the five lifecycle scenarios. Exits non-zero on
# any failed scenario. Captures live fixtures into tests/Fixtures/real/.
#
# REQUIRES a real Ollama install with at least one small model pulled. Set
# HEARTH_VALIDATE_MODEL to the model tag (default qwen2.5:0.5b).
#
# This drives a real server, so it uses real time. It does not sign anything and
# does not start the brew background service; Hearth manages its own ollama serve.
set -uo pipefail

cd "$(dirname "$0")/.."

OLLAMA="${OLLAMA_BIN:-/opt/homebrew/bin/ollama}"
MODEL="${HEARTH_VALIDATE_MODEL:-qwen2.5:0.5b}"
PORT="${HEARTH_VALIDATE_PORT:-11434}"
CTRL_PORT="${HEARTH_VALIDATE_CTRL_PORT:-11455}"
TOKEN="validate-$$"
BIN=".build/debug/Hearth"
WORK="$(mktemp -d)"
CONFIG="$WORK/config.json"
FIXDIR="tests/Fixtures/real"

PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
hr()   { echo "------------------------------------------------------------"; }

HEARTH_PID=""
cleanup() {
  [ -n "$HEARTH_PID" ] && kill -TERM "$HEARTH_PID" 2>/dev/null || true
  sleep 1
  pkill -f "ollama serve" 2>/dev/null || true
  pkill -f "llama-server" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# --- helpers ---------------------------------------------------------------
status_json() { curl -s --max-time 4 -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$CTRL_PORT/status"; }
phase() { status_json | python3 -c "import sys,json; print(json.load(sys.stdin).get('phase','?'))" 2>/dev/null || echo "?"; }
ctrl()  { curl -s --max-time 4 -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$CTRL_PORT/$1"; }
serve_pid()  { pgrep -f "ollama serve" | head -1; }
runner_pids(){ pgrep -f "llama-server" || true; }

wait_phase() { # target timeoutSeconds
  local target="$1" t="$2" i=0
  while [ "$i" -lt "$((t*2))" ]; do
    [ "$(phase)" = "$target" ] && return 0
    sleep 0.5; i=$((i+1))
  done
  return 1
}

wait_leave_healthy() { # timeoutSeconds  (waits until phase is no longer healthy)
  local t="$1" i=0
  while [ "$i" -lt "$((t*2))" ]; do
    [ "$(phase)" != "healthy" ] && return 0
    sleep 0.5; i=$((i+1))
  done
  return 1
}

strays_of() { # currentServePid  -> prints llama-server pids whose parent is not the current serve
  local cur="$1" p pp
  for p in $(runner_pids); do
    [ -z "$p" ] && continue
    pp="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
    [ "$pp" = "$cur" ] || echo "$p"
  done
}

require() {
  command -v "$OLLAMA" >/dev/null 2>&1 || { echo "Real Ollama not found at $OLLAMA. Install it or set OLLAMA_BIN." >&2; exit 2; }
  [ -x "$BIN" ] || swift build >/dev/null || { echo "build failed" >&2; exit 2; }
  mkdir -p "$FIXDIR"
  # ensure a clean slate
  pkill -f "ollama serve" 2>/dev/null || true
  pkill -f "llama-server" 2>/dev/null || true
  sleep 1
}

start_hearth() { # mode: managed|attached
  cat > "$CONFIG" <<JSON
{
  "ollamaBinaryPath": "$OLLAMA",
  "mode": "$1",
  "host": "127.0.0.1",
  "port": $PORT,
  "probeTimeoutSeconds": 2,
  "probeIntervalSeconds": 2,
  "startupGraceSeconds": 30,
  "startupProbeIntervalSeconds": 1,
  "initialBackoffSeconds": 1,
  "localNotifications": false,
  "controlEnabled": true,
  "controlHost": "127.0.0.1",
  "controlPort": $CTRL_PORT,
  "controlToken": "$TOKEN"
}
JSON
  HEARTH_CONFIG="$CONFIG" "$BIN" --headless > "$WORK/hearth.log" 2>&1 &
  HEARTH_PID=$!
}

stop_hearth() { [ -n "$HEARTH_PID" ] && kill -TERM "$HEARTH_PID" 2>/dev/null; wait "$HEARTH_PID" 2>/dev/null; HEARTH_PID=""; }

# --- run -------------------------------------------------------------------
require
echo "Hearth real-runner validation"
echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), Darwin $(uname -r)"
echo "ollama: $($OLLAMA --version 2>&1 | grep -i version | head -1)"
echo "model:  $MODEL"
hr

# === Scenario 1: cold start to Healthy + real /api/ps parse ===
echo "Scenario 1: cold start to Healthy; resident model parsed from real /api/ps"
start_hearth managed
if wait_phase healthy 40; then
  pass "reached Healthy (serve pid $(serve_pid))"
else
  fail "did not reach Healthy in 40s"; tail -5 "$WORK/hearth.log"
fi
# capture live fixtures
curl -s "http://127.0.0.1:$PORT/api/version" -o "$FIXDIR/ollama-version.json"
curl -s "http://127.0.0.1:$PORT/api/tags"    -o "$FIXDIR/ollama-tags.json"
# load the model so it becomes resident, then confirm /status shows it
curl -s --max-time 90 "http://127.0.0.1:$PORT/api/generate" \
  -d "{\"model\":\"$MODEL\",\"prompt\":\"hi\",\"stream\":false,\"keep_alive\":\"5m\"}" >/dev/null
curl -s "http://127.0.0.1:$PORT/api/ps" -o "$FIXDIR/ollama-ps.json"
sleep 3
RESIDENT="$(status_json | python3 -c "import sys,json; d=json.load(sys.stdin); ms=d.get('models',[]); print('yes' if any('$MODEL'.split(':')[0] in m for m in ms) else 'no')" 2>/dev/null || echo no)"
echo "  /status: $(status_json)"
if [ "$RESIDENT" = "yes" ]; then pass "resident model visible via /status"; else fail "resident model not visible via /status"; fi
hr

# === Scenario 2: external SIGKILL -> restart, no orphan ===
echo "Scenario 2: SIGKILL the runner; liveness fails; Hearth restarts (no orphans)"
SP="$(serve_pid)"; echo "  killing ollama serve pid $SP (SIGKILL); its llama-server child: [$(runner_pids)]"
kill -9 "$SP" 2>/dev/null
if wait_leave_healthy 20; then pass "detected the death (phase left Healthy)"; else fail "did not detect the SIGKILL"; fi
if wait_phase healthy 40 && [ -n "$(serve_pid)" ] && [ "$(serve_pid)" != "$SP" ]; then
  pass "restarted to Healthy with a new serve pid $(serve_pid)"
else
  fail "did not restart to Healthy after SIGKILL (phase $(phase))"; tail -5 "$WORK/hearth.log"
fi
sleep 5  # allow the pre-spawn group sweep (SIGTERM then SIGKILL grace) to land
STRAY="$(strays_of "$(serve_pid)")"
echo "  llama-server pids: [$(runner_pids)]; current serve: $(serve_pid); strays: [$STRAY]"
if [ -z "$STRAY" ]; then pass "no orphaned llama-server after external SIGKILL + restart"; else fail "orphaned llama-server: $STRAY"; fi
hr

# === Scenario 3: SIGSTOP wedge -> readiness catches it though PID alive ===
echo "Scenario 3: SIGSTOP the runner (PID alive, API hung); readiness must flag Down"
wait_phase healthy 20 || true
# load a model so a llama-server child exists, to also test orphan reaping
curl -s --max-time 90 "http://127.0.0.1:$PORT/api/generate" \
  -d "{\"model\":\"$MODEL\",\"prompt\":\"hi\",\"stream\":false,\"keep_alive\":\"5m\"}" >/dev/null
sleep 2
SP="$(serve_pid)"; echo "  SIGSTOP ollama serve pid $SP; llama-server child: [$(runner_pids)]"
kill -STOP "$SP" 2>/dev/null
DETECTED=""; ST=""
for i in $(seq 1 40); do
  if [ "$(phase)" != "healthy" ]; then
    ST="$(ps -p "$SP" -o state= 2>/dev/null | tr -d ' ')"
    DETECTED="phase=$(phase) pid=$SP state=$ST"
    break
  fi
  sleep 0.5
done
echo "  at detection: $DETECTED"
if [ -n "$DETECTED" ] && [ -n "$(ps -p "$SP" -o pid= 2>/dev/null)" ]; then
  pass "readiness flagged not-Healthy while PID $SP was still alive (state ${ST:-?}); a liveness check alone would miss this"
else
  kill -CONT "$SP" 2>/dev/null
  fail "wedge not detected while PID alive"
fi
if wait_phase healthy 40 && [ -n "$(serve_pid)" ] && [ "$(serve_pid)" != "$SP" ]; then
  pass "recovered to Healthy with a new serve pid $(serve_pid)"
else
  kill -CONT "$SP" 2>/dev/null
  fail "did not recover after wedge (phase $(phase))"; tail -5 "$WORK/hearth.log"
fi
sleep 5
STRAY="$(strays_of "$(serve_pid)")"
echo "  llama-server pids: [$(runner_pids)]; current serve: $(serve_pid); strays: [$STRAY]"
if [ -z "$STRAY" ]; then pass "no orphaned llama-server after wedge kill + restart"; else fail "orphaned llama-server: $STRAY"; fi
hr

# === Scenario 4: clean shutdown reaps the whole process group ===
echo "Scenario 4: clean shutdown reaps the full process group (no orphans)"
# make sure a model is resident so llama-server exists
curl -s --max-time 90 "http://127.0.0.1:$PORT/api/generate" \
  -d "{\"model\":\"$MODEL\",\"prompt\":\"hi\",\"stream\":false,\"keep_alive\":\"5m\"}" >/dev/null
sleep 2
echo "  before stop: serve=[$(serve_pid)] llama-server=[$(runner_pids)]"
stop_hearth
sleep 5
AFTER_SERVE="$(serve_pid)"; AFTER_RUNNER="$(runner_pids)"
echo "  after stop:  serve=[$AFTER_SERVE] llama-server=[$AFTER_RUNNER]"
if [ -z "$AFTER_SERVE" ] && [ -z "$AFTER_RUNNER" ]; then
  pass "clean shutdown left no ollama serve and no llama-server"
else
  fail "orphans after clean shutdown: serve=[$AFTER_SERVE] llama-server=[$AFTER_RUNNER]"
fi
pkill -f "ollama serve" 2>/dev/null || true; pkill -f "llama-server" 2>/dev/null || true; sleep 1
hr

# === Scenario 5: attached mode (does not own the runner) ===
echo "Scenario 5: attached mode; readiness-only, no spawn or kill"
OLLAMA_HOST=127.0.0.1:$PORT "$OLLAMA" serve > "$WORK/ext-ollama.log" 2>&1 &
EXT=$!
sleep 3
EXT_SERVE="$(serve_pid)"
start_hearth attached
if wait_phase healthy 30; then pass "attached: reached Healthy against the external serve"; else fail "attached: did not reach Healthy"; fi
# Hearth must not have spawned its own serve: the serve pid is unchanged
if [ "$(serve_pid)" = "$EXT_SERVE" ]; then pass "attached: did not spawn its own serve (pid unchanged $EXT_SERVE)"; else fail "attached: serve pid changed (spawned its own?)"; fi
# stop the external runner: Hearth should go not-Healthy but NOT respawn it
kill -TERM "$EXT" 2>/dev/null; pkill -f "ollama serve" 2>/dev/null; sleep 4
if [ "$(phase)" != "healthy" ] && [ -z "$(serve_pid)" ]; then
  pass "attached: went not-Healthy and did NOT respawn the runner it does not own (phase $(phase))"
else
  fail "attached: respawned a runner it does not own or stayed Healthy (phase $(phase), serve [$(serve_pid)])"
fi
stop_hearth
hr

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
