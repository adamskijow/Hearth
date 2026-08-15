#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Fail closed before signing: a release tag must name the checked-out commit,
# match the bundle version exactly, and point to a commit already on
# origin/main. This prevents an innocent tag typo or an off-branch tag from
# publishing an ambiguously versioned privileged Mac app.
set -euo pipefail

cd "$(dirname "$0")/.."

TAG="${1:-${GITHUB_REF_NAME:-}}"
[ -n "$TAG" ] || { echo "usage: $0 v<bundle-version>" >&2; exit 2; }

PLIST="Sources/Hearth/Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
EXPECTED="v${VERSION}"

[ "$TAG" = "$EXPECTED" ] || {
  echo "release tag $TAG does not match Hearth bundle version $EXPECTED" >&2
  exit 1
}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "bundle version $VERSION is not strict major.minor.patch" >&2
  exit 1
}
[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || {
  echo "bundle build $BUILD is not a positive integer" >&2
  exit 1
}

TAG_COMMIT="$(git rev-parse "${TAG}^{commit}")"
HEAD_COMMIT="$(git rev-parse HEAD)"
[ "$TAG_COMMIT" = "$HEAD_COMMIT" ] || {
  echo "release tag $TAG does not identify checked-out HEAD" >&2
  exit 1
}
git show-ref --verify --quiet refs/remotes/origin/main || {
  echo "origin/main is unavailable; checkout must use fetch-depth: 0" >&2
  exit 1
}
git merge-base --is-ancestor "$HEAD_COMMIT" origin/main || {
  echo "release commit is not on origin/main" >&2
  exit 1
}

echo "Release ref verified: $TAG (build $BUILD) at $HEAD_COMMIT on origin/main."
