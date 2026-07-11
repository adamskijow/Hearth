#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Rebuild Hearth Monitor's committed PNG and ICNS assets from its vector source.
# qlmanage is used only as Apple's local SVG renderer; packaging consumes the
# committed outputs and does not depend on Quick Look.
set -euo pipefail

cd "$(dirname "$0")/.."

SVG="assets/monitor-icon.svg"
PNG="assets/MonitorIcon-1024.png"
ICNS="assets/MonitorIcon.icns"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

qlmanage -t -s 1024 -o "$TMP" "$SVG" >/dev/null
cp "$TMP/monitor-icon.svg.png" "$PNG"

SET="$TMP/MonitorIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$PNG" --out "$SET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$PNG" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$ICNS"

echo "Wrote $PNG and $ICNS"
