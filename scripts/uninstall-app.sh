#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Remove a local Hearth install: the app, its config, logs, and state. Mirrors
# the Homebrew cask's `zap`. Prompts before deleting unless --yes is passed.
set -euo pipefail

YES=0
[ "${1:-}" = "--yes" ] && YES=1

targets=(
  "/Applications/Hearth.app"
  "$HOME/Applications/Hearth.app"
  "$HOME/Library/Application Support/Hearth"
  "$HOME/Library/Logs/Hearth"
)

present=()
for target in "${targets[@]}"; do
  [ -e "$target" ] && present+=("$target")
done

if [ "${#present[@]}" -eq 0 ]; then
  echo "Nothing to remove; Hearth does not appear to be installed."
  exit 0
fi

echo "This will quit Hearth and remove:"
for target in "${present[@]}"; do echo "  $target"; done

if [ "$YES" -ne 1 ]; then
  printf "Proceed? [y/N] "
  read -r reply
  case "$reply" in
    y | Y | yes | Yes) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

pkill -x Hearth 2>/dev/null || true
sleep 1
for target in "${present[@]}"; do
  rm -rf "$target"
done
# Remove the `hearth` CLI symlink `make install` created, only if it is our symlink
# (never the root daemon's real installed binary at /usr/local/bin/hearth).
for link in /usr/local/bin/hearth "$HOME/.local/bin/hearth"; do
  [ -L "$link" ] && rm -f "$link"
done

echo "Removed."
echo "If you had enabled Start at Login, the now-stale login item clears on the"
echo "next login, or remove it in System Settings > General > Login Items."
