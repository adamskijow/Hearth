#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# A live, narrated demo of the one thing Hearth exists for: recovering a runner
# that is ALIVE but WEDGED (process up, port open, not answering), the failure a
# liveness check (launchd KeepAlive, systemd) misses entirely. It supervises a
# stand-in runner (no Ollama needed), freezes it mid-flight, and shows Hearth
# notice by readiness and recover on its own.
#
# Run it with:  make demo   (or ./scripts/demo.sh)
#
# It is fully isolated (HEARTH_DATA_DIR + HEARTH_CONFIG), so it is safe to run
# alongside a real Hearth: it never touches the shared state or another instance's
# runner. It is a local helper for the README's wedge-recovery GIF, not a CI step.
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${HEARTH_DEMO_PORT:-11898}"
CTRL_PORT="${HEARTH_DEMO_CTRL_PORT:-11936}"
CTRL_TOKEN="demo-token-$$"
WORKDIR="$(mktemp -d)"
CONFIG="$WORKDIR/config.json"
DATA_DIR="$WORKDIR/data"
RUNNER="$PWD/scripts/fake-runner.py"
BIN=".build/debug/Hearth"

if [ -t 1 ]; then
  B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; X=$'\033[0m'
else
  B=""; D=""; G=""; Y=""; R=""; C=""; X=""
fi

HEARTH_PID=""
cleanup() {
  [ -n "$HEARTH_PID" ] && kill -TERM "$HEARTH_PID" 2>/dev/null || true
  sleep 1
  pkill -f "fake-runner.py" 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

say()  { printf '%s\n' "$*"; }
step() { printf '\n%s%s%s\n' "$B" "$*" "$X"; }

status() {
  curl -fs --max-time 2 -H "Authorization: Bearer $CTRL_TOKEN" \
    "http://127.0.0.1:$CTRL_PORT/status" 2>/dev/null
}
field() { status | python3 -c "import sys,json;print(json.load(sys.stdin).get('$1',''))" 2>/dev/null || true; }
phase() { field phase; }
runner_pid() { pgrep -f "fake-runner.py" | head -1 || true; }
alive() { ps -p "$1" -o pid= >/dev/null 2>&1; }

say "${B}Hearth wedge-recovery demo${X}"
say "${D}A runner can be alive but wedged: process up, port open, not answering.${X}"
say "${D}A liveness check (launchd KeepAlive, systemd) sees 'alive' and does nothing.${X}"
say "${D}Hearth probes readiness, so it catches it. Watch.${X}"

step "Building Hearth..."
swift build >/dev/null
say "  ${G}done${X}"

cat > "$CONFIG" <<JSON
{
  "ollamaBinaryPath": "$RUNNER",
  "host": "127.0.0.1",
  "port": $PORT,
  "probeIntervalSeconds": 2,
  "probeTimeoutSeconds": 2,
  "startupGraceSeconds": 6,
  "startupProbeIntervalSeconds": 0.5,
  "initialBackoffSeconds": 1,
  "maxBackoffSeconds": 4,
  "failingProbeIntervalSeconds": 3,
  "crashLoopThreshold": 20,
  "localNotifications": false,
  "controlEnabled": true,
  "controlHost": "127.0.0.1",
  "controlPort": $CTRL_PORT,
  "controlToken": "$CTRL_TOKEN"
}
JSON

step "Starting Hearth, supervising a stand-in runner..."
HEARTH_DATA_DIR="$DATA_DIR" HEARTH_CONFIG="$CONFIG" "$BIN" --headless >"$WORKDIR/hearth.log" 2>&1 &
HEARTH_PID=$!

for _ in $(seq 1 30); do
  [ "$(phase)" = "healthy" ] && break
  sleep 0.5
done
PID1="$(runner_pid)"
if [ "$(phase)" != "healthy" ] || [ -z "$PID1" ]; then
  say "  ${R}runner did not come up; see $WORKDIR/hearth.log${X}"; exit 1
fi
say "  ${G}healthy${X} - runner answering /api/version  ${D}(pid $PID1)${X}"
sleep 1

step "Freezing the runner (SIGUSR1): it stays alive, but stops answering."
kill -USR1 "$PID1"
sleep 0.5
if alive "$PID1"; then
  say "  runner process ${C}$PID1${X} is ${G}still alive${X}"
  say "  ${D}a liveness check would report 'fine' and stop here.${X}"
fi

step "Hearth keeps probing readiness..."
last="" ; PID2=""
for _ in $(seq 1 60); do
  p="$(phase)"
  if [ -n "$p" ] && [ "$p" != "$last" ] && [ -n "$last" ]; then
    case "$p" in
      down)       say "  ${Y}Hearth: runner not answering -> phase 'down'${X}  ${D}(pid $PID1 alive: $(alive "$PID1" && echo yes || echo no))${X}" ;;
      restarting) say "  ${Y}Hearth: killing the wedged runner, starting a fresh one${X}" ;;
      failing)    say "  ${Y}Hearth: still not ready, backing off${X}" ;;
    esac
  fi
  [ -n "$p" ] && last="$p"
  np="$(runner_pid)"
  if [ -n "$np" ] && [ "$np" != "$PID1" ] && [ "$p" = "healthy" ]; then PID2="$np"; break; fi
  sleep 0.5
done

step "Recovered."
if [ -n "$PID2" ]; then
  say "  ${G}healthy again${X} - a ${B}fresh${X} runner is answering  ${D}(pid $PID2, was $PID1)${X}"
else
  say "  ${G}healthy again${X} - the runner recovered  ${D}(was $PID1)${X}"
fi
reason="$(field lastRestartReason)"
[ -n "$reason" ] && say "  ${D}Hearth's recorded reason: $reason${X}"

step "${B}That is the whole point.${X}"
say "  The runner process never died, so a liveness check would have done nothing."
say "  Hearth caught the wedge by readiness and recovered it on its own, hands-off."
say ""
