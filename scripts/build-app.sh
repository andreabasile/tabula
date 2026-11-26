#!/bin/bash
# Builds Tabula.app with libpq and its dependencies inside the bundle, and signs it.
# With --install it copies the app to /Applications and reopens it. The Apple Development
# signature stays the same across builds, so the Keychain does not ask for access every time.
set -euo pipefail
cd "$(dirname "$0")/.."

# Signs with the first "Apple Development" certificate in the Keychain, stable across builds;
# without one (or with TABULA_SIGN_IDENTITY="-", as in the GitHub Action) it signs ad-hoc.
DEFAULT_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)
IDENTITY="${TABULA_SIGN_IDENTITY:-${DEFAULT_IDENTITY:--}}"
swift build -c release --product Tabula
BIN="$(swift build -c release --show-bin-path)/Tabula"
APP=build/Tabula.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$APP/Contents/Resources"
# English is the source language: the catalog compiles at most its plural rules for it, no
# Localizable.strings. Without an en.lproj a Mac that prefers English but also lists Italian,
# French or German would get that language instead.
mkdir -p "$APP/Contents/Resources/en.lproj"
touch "$APP/Contents/Resources/en.lproj/Localizable.strings"
cp "$BIN" "$APP/Contents/MacOS/Tabula"
python3 -I scripts/bundle-dylibs.py "$APP/Contents/MacOS/Tabula" "$APP/Contents/Frameworks"

# Homebrew's dylibs are built for the build machine's macOS: when that is newer than
# LSMinimumSystemVersion the app does not open on older Macs. Releases are built in CI
# (where $CI is set), so there this is an error; local builds only get a warning.
MIN_MACOS=$(plutil -extract LSMinimumSystemVersion raw Resources/Info.plist)
for lib in "$APP"/Contents/Frameworks/*.dylib; do
    minos=$(vtool -show-build "$lib" | awk '/minos/ {print $2; exit}')
    if [[ "$(printf '%s\n%s\n' "$MIN_MACOS" "$minos" | sort -V | tail -1)" != "$MIN_MACOS" ]]; then
        message="$(basename "$lib") requires macOS $minos, but the app declares $MIN_MACOS"
        if [[ -n "${CI:-}" ]]; then
            echo "error: $message (build on macOS $MIN_MACOS)" >&2
            exit 1
        fi
        echo "warning: $message: this build may not open on older Macs" >&2
    fi
done

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
    if pgrep -x Tabula >/dev/null; then
        echo "error: Tabula is still running; quit it and run again" >&2
        exit 1
    fi
    rm -rf /Applications/Tabula.app
    cp -R "$APP" /Applications/
    open /Applications/Tabula.app
    echo "installed and opened"
fi
