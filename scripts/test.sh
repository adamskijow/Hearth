#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Run the SupervisorCore test suite.
#
# The tests use Swift Testing. On a Mac with only the Command Line Tools
# installed (no full Xcode), which is the common state on a headless box, the
# Swift Testing framework is not on the default search path, and this toolchain's
# `swift test` only loads and runs the suite when the framework path and runtime
# rpaths are passed explicitly. This script detects the right directory for both
# the Command Line Tools and full Xcode layouts and passes them. On a machine
# with full Xcode, a plain `swift test` also works.
set -euo pipefail

cd "$(dirname "$0")/.."

DEV="$(xcode-select -p)"

# Command Line Tools layout.
FWDIR="$DEV/Library/Developer/Frameworks"
LIBDIR="$DEV/Library/Developer/usr/lib"

# Full Xcode layout (fallback).
if [ ! -d "$FWDIR/Testing.framework" ]; then
  FWDIR="$DEV/Platforms/MacOSX.platform/Developer/Library/Frameworks"
  LIBDIR="$DEV/Platforms/MacOSX.platform/Developer/usr/lib"
fi

if [ ! -d "$FWDIR/Testing.framework" ]; then
  echo "Could not locate Testing.framework under $DEV." >&2
  echo "Trying a plain swift test; install Xcode or the Command Line Tools if this fails." >&2
  exec swift test "$@"
fi

exec swift test --disable-xctest --enable-swift-testing \
  -Xswiftc -F -Xswiftc "$FWDIR" \
  -Xlinker -F -Xlinker "$FWDIR" \
  -Xlinker -rpath -Xlinker "$FWDIR" \
  -Xlinker -rpath -Xlinker "$LIBDIR" \
  "$@"
