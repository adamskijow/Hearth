#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Local CI for Hearth. There is no hosted runner; this is the gate you run on
# your own machine, and the pre-push hook (scripts/install-hooks.sh) runs it for
# you before every push.
#
# Default stages are headless safe (no desktop session, no Ollama):
#   scripts/ci.sh            build (debug + release), unit tests, lint
#   scripts/ci.sh --smoke    also run the fake-runner smoke test (needs a desktop)
#   scripts/ci.sh --real     also run the real Ollama gate (needs ollama + a model)
#   scripts/ci.sh --all      everything above
#
# Exits non-zero if any stage fails. Build failures stop early; test and lint
# failures are collected so one run shows the full picture.
set -uo pipefail

cd "$(dirname "$0")/.."

SMOKE=0; REAL=0
for arg in "$@"; do
  case "$arg" in
    --smoke) SMOKE=1 ;;
    --real)  REAL=1 ;;
    --all)   SMOKE=1; REAL=1 ;;
    -h|--help) sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $arg (see --help)" >&2; exit 2 ;;
  esac
done

FAIL=0
section() { echo; echo "=== $1 ==="; }
ok()      { echo "  ok"; }
bad()     { echo "  FAIL: $1"; FAIL=1; }
die()     { echo "  FAIL: $1"; exit 1; }

section "Build (debug)"
swift build && ok || die "debug build failed"

section "Build (release)"
swift build -c release && ok || die "release build failed"

section "Unit tests"
./scripts/test.sh && ok || bad "unit tests failed"

section "Lint: no em dashes (project rule: none in code, comments, docs, commits)"
# Build the em dash byte sequence with printf so this script contains no literal
# em dash to trip its own check. git grep returns 0 when it finds a match.
EMDASH="$(printf '\xe2\x80\x94')"
if MATCHES="$(git grep -nI -F -e "$EMDASH" -- . ':!assets/*.png' ':!assets/*.icns' 2>/dev/null)"; then
  echo "$MATCHES"
  bad "em dash found"
else
  ok
fi

section "Lint: SPDX header on every Swift source"
MISSING=""
for f in $(git ls-files '*.swift'); do
  head -3 "$f" | grep -q "SPDX-License-Identifier" || MISSING="$MISSING $f"
done
if [ -n "$MISSING" ]; then
  echo "  missing SPDX:$MISSING"
  bad "Swift files without an SPDX header"
else
  ok
fi

if [ "$SMOKE" = "1" ]; then
  section "Smoke test (fake runner, needs a desktop session)"
  ./scripts/smoke-test.sh && ok || bad "smoke test failed"
fi

if [ "$REAL" = "1" ]; then
  section "Real runner gate (needs Ollama and a pulled model)"
  ./scripts/validate-real.sh && ok || bad "real runner gate failed"
fi

echo
if [ "$FAIL" = "0" ]; then
  echo "CI passed."
else
  echo "CI FAILED."
fi
exit "$FAIL"
