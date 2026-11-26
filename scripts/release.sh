#!/bin/bash
# Starts a release: creates and pushes the tag, then the GitHub Action builds, publishes the DMG
# and updates the cask in the tap. Usage: ./scripts/release.sh 1.0.1
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?missing version, e.g. 1.0.1}"
[[ -z "$(git status --porcelain)" ]] || { echo "there are uncommitted changes"; exit 1; }

git tag "v$VERSION"
git push -q origin main "v$VERSION"
echo "tag v$VERSION pushed: follow the build with 'gh run watch -R andreabasile/tabula'"
