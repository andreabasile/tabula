#!/bin/bash
# Extracts the localizable strings from the code and merges them into Resources/Localizable.xcstrings.
# English is the source language: the keys are the English texts, translators add it/fr/de.
set -euo pipefail
cd "$(dirname "$0")/.."

CATALOG=Resources/Localizable.xcstrings
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

swift build --product Tabula -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT"
xcrun xcstringstool sync "$CATALOG" --stringsdata "$OUT"/*.stringsdata
echo "ok: $CATALOG"
