#!/bin/bash
# Avvia una release: crea e pubblica il tag, poi la GitHub Action compila, pubblica il DMG
# e aggiorna il cask nel tap. Uso: ./scripts/release.sh 1.0.1
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?versione mancante, es. 1.0.1}"
[[ -z "$(git status --porcelain)" ]] || { echo "ci sono modifiche non committate"; exit 1; }

git tag "v$VERSION"
git push -q origin main "v$VERSION"
echo "tag v$VERSION pubblicato: segui la build con 'gh run watch -R andreabasile/tabula'"
