#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Historical Monitor publication entry point. See docs/hearth-monitor.md.
set -euo pipefail

echo "Hearth Monitor was retired on September 7, 2026. New releases and App Store uploads are disabled." >&2
echo "See docs/hearth-monitor.md. Use scripts/release.sh for full Hearth." >&2
exit 2
