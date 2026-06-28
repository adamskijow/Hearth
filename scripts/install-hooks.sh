#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Point git at the in-repo hooks so local CI (scripts/ci.sh) runs before every
# push. The hooks live under version control in scripts/hooks, so this is just a
# one-time `git config` per clone.
set -euo pipefail

cd "$(dirname "$0")/.."

git config core.hooksPath scripts/hooks
chmod +x scripts/hooks/* 2>/dev/null || true

echo "Installed: core.hooksPath -> scripts/hooks"
echo "pre-push now runs scripts/ci.sh (build, tests, lint)."
echo "Bypass a single push with: git push --no-verify"
echo "Uninstall with: git config --unset core.hooksPath"
