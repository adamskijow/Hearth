#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Capture a REAL out-of-memory stderr signature from a runner, to close the one
# UNVERIFIED item in docs/limitations.md: Hearth's OOM heuristics are confirmed
# absent from a healthy runner's output (no false positives), but have never
# been confirmed to FIRE on a real Metal OOM, because that could not be induced
# on the 128 GiB development hardware.
#
# If you have a memory-constrained Apple Silicon Mac (say 8 or 16 GiB) and a
# model too large for it, you can capture the real signature and contribute it:
#
#   ./scripts/capture-oom.sh <model-that-wont-fit>
#
# It starts `ollama serve` with its stderr captured, sends one generate request
# that should blow past unified memory, and, if the runner dies, prints the tail
# of its stderr and checks it against Hearth's oomSignatures. A match is the
# proof we lack; paste the captured lines into a PR updating
# Tests/SupervisorCoreTests/Fixtures and RunnerHeuristics.
#
# This does NOT fabricate anything. If nothing OOMs (you have the memory for the
# model), it says so and captures nothing.
set -euo pipefail

MODEL="${1:-}"
[ -n "$MODEL" ] || { echo "usage: $0 <model-that-exceeds-this-Mac's-memory>"; exit 2; }
command -v ollama >/dev/null || { echo "ollama not found on PATH"; exit 1; }

RAM_GIB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
echo "This Mac has ${RAM_GIB} GiB unified memory."
if [ "$RAM_GIB" -ge 64 ]; then
  echo "warning: on ${RAM_GIB} GiB, most models fit and will NOT OOM. This harness"
  echo "is meant for a memory-constrained Mac; continuing, but expect no capture."
fi

WORKDIR="$(mktemp -d)"
STDERR="$WORKDIR/ollama.stderr"
PORT="${OLLAMA_OOM_PORT:-11987}"
cleanup() { [ -n "${SERVE_PID:-}" ] && kill "$SERVE_PID" 2>/dev/null || true; rm -rf "$WORKDIR"; }
trap cleanup EXIT

echo "Starting ollama serve on 127.0.0.1:${PORT}, capturing stderr..."
OLLAMA_HOST="127.0.0.1:${PORT}" ollama serve >"$WORKDIR/ollama.stdout" 2>"$STDERR" &
SERVE_PID=$!

for _ in $(seq 1 30); do
  curl -fs --max-time 2 "http://127.0.0.1:${PORT}/api/version" >/dev/null 2>&1 && break
  sleep 0.5
done

echo "Requesting a generation from ${MODEL} (expected to exhaust memory)..."
curl -s --max-time 120 "http://127.0.0.1:${PORT}/api/generate" \
  -d "{\"model\":\"${MODEL}\",\"prompt\":\"hello\",\"stream\":false}" >/dev/null 2>&1 || true
sleep 2

if kill -0 "$SERVE_PID" 2>/dev/null; then
  echo
  echo "The runner is still alive: no OOM was induced (the model fit, or the"
  echo "request was rejected cleanly). Nothing to capture on this Mac."
  exit 0
fi

echo
echo "The runner died. Its stderr tail:"
echo "----------------------------------------"
tail -n 25 "$STDERR" | sed 's/^/  /'
echo "----------------------------------------"

# Cross-check against the signatures Hearth ships, the same list as
# RunnerHeuristics.oomSignatures.
SIGNATURES=(
  "out of memory" "outofmemory" "cannot allocate" "failed to allocate"
  "unable to allocate" "insufficient memory" "not enough memory"
  "vk_error_out_of_device_memory" "ggml_metal_graph_compute" "mtlbuffer"
  "metal buffer" "ggml_backend_metal_buffer"
)
HAYSTACK="$(tr '[:upper:]' '[:lower:]' < "$STDERR")"
MATCHED=""
for sig in "${SIGNATURES[@]}"; do
  if printf '%s' "$HAYSTACK" | grep -qF "$sig"; then MATCHED="$MATCHED\n  matched: $sig"; fi
done

if [ -n "$MATCHED" ]; then
  echo
  echo "This output WOULD be classified out-of-memory by Hearth:"
  printf '%b\n' "$MATCHED"
  echo
  echo "Please open a PR: add the captured lines as a fixture under"
  echo "Tests/SupervisorCoreTests/Fixtures and reference them from a test that"
  echo "asserts RunnerHeuristics.classify returns .outOfMemory. That closes the"
  echo "UNVERIFIED note in docs/limitations.md."
else
  echo
  echo "The runner died but NONE of Hearth's OOM signatures matched. This is"
  echo "itself a finding: capture the tail above and open an issue, so the"
  echo "signature list can be extended to recognize this real OOM."
fi
