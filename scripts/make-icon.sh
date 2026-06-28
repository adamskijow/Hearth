#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build assets/AppIcon.icns from assets/AppIcon-1024.png using macOS built-ins
# (sips + iconutil). Run after editing the icon source.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="assets/AppIcon-1024.png"
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"
for sz in 16 32 128 256 512; do
  sips -z "$sz" "$sz" "$SRC" --out "$SET/icon_${sz}x${sz}.png" >/dev/null
  two=$((sz * 2))
  sips -z "$two" "$two" "$SRC" --out "$SET/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o assets/AppIcon.icns
echo "wrote assets/AppIcon.icns ($(du -h assets/AppIcon.icns | cut -f1))"
