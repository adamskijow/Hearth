#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Build, ad-hoc sign, and install Hearth.app for local use, so you can run and
# dogfood it before there is a Developer ID signed, notarized release. Ad-hoc
# signing gives the bundle a stable local code identity (which the login item and
# notifications want); it is NOT Developer ID and NOT notarized, so it is for your
# own machine, not distribution. For that, use scripts/release.sh.
set -euo pipefail

cd "$(dirname "$0")/.."

DEST="${HEARTH_INSTALL_DIR:-/Applications}"
APP="dist/Hearth.app"

# Guard a typo'd or bogus HEARTH_INSTALL_DIR before any rm -rf runs against it.
if [ ! -d "$DEST" ]; then
  echo "HEARTH_INSTALL_DIR=\"$DEST\" is not a directory." >&2
  exit 1
fi

./scripts/package-app.sh

echo "Ad-hoc signing (stable local identity, not Developer ID, not notarized)..."
codesign --force --sign - "$APP/Contents/MacOS/Hearth"
codesign --force --sign - "$APP"
codesign --verify --verbose=1 "$APP"

# Fall back to ~/Applications if /Applications is not writable.
if [ ! -w "$DEST" ]; then
  echo "$DEST is not writable; installing to ~/Applications instead."
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi

# Stop a running copy so the bundle can be replaced cleanly.
pkill -x Hearth 2>/dev/null || true
sleep 1

echo "Installing to $DEST ..."
rm -rf "$DEST/Hearth.app"
cp -R "$APP" "$DEST/Hearth.app"

echo
echo "Installed: $DEST/Hearth.app"
echo "Launch it:  open \"$DEST/Hearth.app\"   (a flame appears in the menubar)"
echo
echo "First run:"
echo "  - Approve the notification prompt if you want alerts."
echo "  - Open Preferences from the menu to pick your runner and binary path"
echo "    (it auto-detects Ollama, LM Studio, and mlx_lm)."
echo "  - Turn on 'Start at login' from the menu to keep it running."
