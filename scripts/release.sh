#!/bin/bash
# Pubblica una release: imposta la versione, compila, carica Tabula-<versione>.zip su GitHub
# e aggiorna Casks/tabula.rb in andreabasile/homebrew-tap. Uso: ./scripts/release.sh 1.0.1
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?versione mancante, es. 1.0.1}"
REPO=andreabasile/tabula
TAP=andreabasile/homebrew-tap
ZIP="build/Tabula-$VERSION.zip"

[[ -z "$(git status --porcelain)" ]] || { echo "ci sono modifiche non committate"; exit 1; }

BUILD=$(git rev-list --count HEAD)
plutil -replace CFBundleShortVersionString -string "$VERSION" Resources/Info.plist
plutil -replace CFBundleVersion -string "$BUILD" Resources/Info.plist
if ! git diff --quiet Resources/Info.plist; then
    git commit -q -m "chore: versione $VERSION" Resources/Info.plist
fi

./scripts/build-app.sh
ditto -c -k --keepParent build/Tabula.app "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)

git tag "v$VERSION"
git push -q origin main "v$VERSION"
gh release create "v$VERSION" "$ZIP" --repo "$REPO" --title "Tabula $VERSION" --generate-notes

CASK=$(sed -e "s/__VERSION__/$VERSION/" -e "s/__SHA256__/$SHA/" scripts/tabula.rb.template)
CURRENT_SHA=$(gh api "repos/$TAP/contents/Casks/tabula.rb" --jq .sha 2>/dev/null || true)
gh api -X PUT "repos/$TAP/contents/Casks/tabula.rb" \
    -f message="tabula $VERSION" \
    -f content="$(printf '%s\n' "$CASK" | base64)" \
    ${CURRENT_SHA:+-f sha="$CURRENT_SHA"} >/dev/null
echo "rilasciata $VERSION (sha256 $SHA)"
