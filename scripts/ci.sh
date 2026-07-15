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

SWIFT_DISABLE_SANDBOX=0
if [ "$(xcode-select -p 2>/dev/null || true)" = "/Library/Developer/CommandLineTools" ] \
   && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/hearth-ci-clang-cache"
  export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/hearth-ci-swiftpm-cache"
  SWIFT_DISABLE_SANDBOX=1
elif [ "$(xcode-select -p 2>/dev/null || true)" = "/Library/Developer/CommandLineTools" ] \
   && [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk" ]; then
  export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
  export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/hearth-ci-clang-cache"
  export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/hearth-ci-swiftpm-cache"
  SWIFT_DISABLE_SANDBOX=1
fi

swift_build() {
  if [ "$SWIFT_DISABLE_SANDBOX" = "1" ]; then
    swift build --disable-sandbox "$@"
  else
    swift build "$@"
  fi
}

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
swift_build && ok || die "debug build failed"

section "Build (release)"
swift_build -c release && ok || die "release build failed"

section "Hearth Monitor App Store boundary"
if ./scripts/package-monitor-app.sh && ./scripts/audit-monitor-boundary.sh; then
  ok
else
  die "Hearth Monitor sandbox package or boundary audit failed"
fi

section "Unit tests"
./scripts/test.sh && ok || bad "unit tests failed"

section "Lint: whitespace"
if git diff --check \
   && git diff --cached --check \
   && git diff-tree --check --no-commit-id -r HEAD; then
  ok
else
  bad "whitespace errors found"
fi

section "Lint: no em dashes (project rule: none in code, comments, docs, commits)"
# Build the em dash byte sequence with printf so this script contains no literal
# em dash to trip its own check. git grep returns 0 when it finds a match.
EMDASH="$(printf '\xe2\x80\x94')"
if MATCHES="$(git grep --untracked -nI -F -e "$EMDASH" -- . ':!assets/*.png' ':!assets/*.icns' 2>/dev/null)"; then
  echo "$MATCHES"
  bad "em dash found"
else
  ok
fi

section "Lint: SPDX header on every Swift source"
MISSING=""
while IFS= read -r -d '' f; do
  # Cached paths can be absent before a deletion is staged. Check only files
  # present in the working tree, including new untracked Swift sources.
  [ -f "$f" ] || continue
  head -3 "$f" | grep -q "SPDX-License-Identifier" || MISSING="$MISSING $f"
done < <(git ls-files --cached --others --exclude-standard -z -- '*.swift')
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
