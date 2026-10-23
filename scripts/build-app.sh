#!/bin/bash
# Compila, assembla Tabula.app con libpq e dipendenze dentro il bundle, lo firma.
# Con --install lo mette in /Applications e lo riapre. La firma Apple Development
# resta stabile fra le build, cosi' il Portachiavi non richiede il permesso ogni volta.
set -euo pipefail
cd "$(dirname "$0")/.."

# TABULA_SIGN_IDENTITY="-" firma ad-hoc, come fa la GitHub Action senza certificato.
IDENTITY="${TABULA_SIGN_IDENTITY:-Apple Development: NOME (TEAMID)}"
swift build -c release --product Tabula
BIN="$(swift build -c release --show-bin-path)/Tabula"
APP=build/Tabula.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp "$BIN" "$APP/Contents/MacOS/Tabula"
python3 -I scripts/bundle-dylibs.py "$APP/Contents/MacOS/Tabula" "$APP/Contents/Frameworks"

for lib in "$APP"/Contents/Frameworks/*.dylib; do
    codesign --force --timestamp=none --sign "$IDENTITY" "$lib"
done
codesign --force --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"
echo "ok: $APP"

if [[ "${1:-}" == "--install" ]]; then
    # SIGTERM makes Tabula quit normally, closing the tunnels it opened; wait for it.
    pkill -x Tabula || true
    for _ in $(seq 1 40); do pgrep -x Tabula >/dev/null || break; sleep 0.25; done
    rm -rf /Applications/Tabula.app
    cp -R "$APP" /Applications/
    open /Applications/Tabula.app
    echo "installata e aperta"
fi
