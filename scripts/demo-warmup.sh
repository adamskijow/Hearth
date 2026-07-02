#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# A live, narrated demo of recovery you cannot feel: the runner is killed out
# from under Hearth, restarted, and then the models that were resident before
# the crash are loaded back into memory (warmModelsAfterRestart), so the next
# request pays no multi-gigabyte cold start. Uses the stand-in runner; no
# Ollama needed. Fully isolated, safe to run next to a real Hearth.
#
# Run it with:  ./scripts/demo-warmup.sh   (the README GIF is recorded from it
# with vhs: `vhs scripts/demo-warmup.tape`)
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${HEARTH_DEMO_PORT:-11897}"
CTRL_PORT="${HEARTH_DEMO_CTRL_PORT:-11937}"
CTRL_TOKEN="demo-token-$$"
WORKDIR="$(mktemp -d)"
CONFIG="$WORKDIR/config.json"
DATA_DIR="$WORKDIR/data"
RUNNER="$PWD/scripts/fake-runner.py"
BIN=".build/debug/Hearth"

if [ -t 1 ]; then
  B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; R=$'\033[31m'; X=$'\033[0m'
else
  B=""; D=""; G=""; Y=""; C=""; R=""; X=""
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
models() { status | python3 -c "import sys,json;print(', '.join(json.load(sys.stdin).get('models',[])))" 2>/dev/null || true; }
phase() { field phase; }
runner_pid() { pgrep -f "fake-runner.py" | head -1 || true; }

say "${B}Hearth model warm-up demo${X}"
say "${D}A restarted runner answers probes fast, but its models are gone: the next${X}"
say "${D}request pays a multi-gigabyte cold load. With warmModelsAfterRestart on,${X}"
say "${D}Hearth reloads what was resident, so recovery is invisible. Watch.${X}"

step "Building Hearth..."
swift build >/dev/null
say "  ${G}done${X}"

cat > "$CONFIG" <<JSON
{
  "ollamaBinaryPath": "$RUNNER",
  "host": "127.0.0.1",
  "port": $PORT,
  "probeIntervalSeconds": 1,
  "probeTimeoutSeconds": 2,
  "startupGraceSeconds": 6,
  "startupProbeIntervalSeconds": 0.5,
  "initialBackoffSeconds": 1,
  "warmModelsAfterRestart": true,
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
  [ "$(phase)" = "healthy" ] && [ -n "$(models)" ] && break
  sleep 0.5
done
PID1="$(runner_pid)"
if [ "$(phase)" != "healthy" ] || [ -z "$PID1" ]; then
  say "  ${R}runner did not come up; see $WORKDIR/hearth.log${X}"; exit 1
fi
say "  ${G}healthy${X} - resident model: ${C}$(models)${X}  ${D}(pid $PID1)${X}"
sleep 1

step "Killing the runner outright (SIGKILL): process gone, models gone with it."
kill -9 "$PID1"

step "Hearth notices, restarts, and warms the model back up..."
last=""
for _ in $(seq 1 60); do
  p="$(phase)"
  if [ -n "$p" ] && [ "$p" != "$last" ] && [ -n "$last" ]; then
    case "$p" in
      down)       say "  ${Y}Hearth: runner gone -> phase 'down'${X}" ;;
      restarting) say "  ${Y}Hearth: starting a fresh runner${X}" ;;
      healthy)    say "  ${G}Hearth: healthy again${X} ${D}(pid $(runner_pid), was $PID1)${X}" ;;
    esac
  fi
  [ -n "$p" ] && last="$p"
  if [ "$p" = "healthy" ] && HEARTH_DATA_DIR="$DATA_DIR" "$BIN" events -n 8 2>/dev/null | grep -q "Warmed"; then
    break
  fi
  sleep 0.5
done

step "The warm-up, in Hearth's own event log:"
HEARTH_DATA_DIR="$DATA_DIR" "$BIN" events -n 6 2>/dev/null | sed 's/^/  /'

step "Done."
say "  ${G}Resident again: ${C}$(models)${X}"
say "  ${D}The next request pays nothing. Recovery you cannot feel.${X}"
