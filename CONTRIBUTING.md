# Contributing to Tabula

Thanks for your interest! Bug reports, fixes and small features are welcome.

## Requirements

- macOS 15+ on Apple Silicon
- Swift 6 / a recent Xcode
- `brew install libpq` (needed to build)
- AWS CLI v2, only if you work on Aurora DSQL

## Build, run, test

```bash
swift build                       # compile
swift test                        # core tests (must pass)
swift run Tabula                  # run in development
./scripts/build-app.sh            # signed build/Tabula.app
./scripts/build-app.sh --install  # copy to /Applications and open
./scripts/sync-strings.sh         # update Resources/Localizable.xcstrings from the source
./scripts/release.sh 1.0.1        # tag v1.0.1: the GitHub Action publishes the DMG and updates the cask
```

## Code layout

- `Sources/TabulaCore`: the testable core (connections, DSQL tokens, SQL, tunnels), no UI.
- `Sources/Tabula`: the SwiftUI/AppKit app.

## Conventions

- Keep changes small and focused; one topic per pull request.
- Core logic gets a test in `Tests/TabulaCoreTests`.
- `swift test` must pass before you open a pull request.

## Localization

UI strings are written in English in the Swift code; English is the source language of the
string catalog `Resources/Localizable.xcstrings`, and Italian, French and German are translations.

After adding or changing UI strings, run `./scripts/sync-strings.sh`: it extracts the strings
from the source code into the catalog. Then, if you can, add the Italian, French and German
translations; missing translations fall back to English.

Translations can be edited in Xcode's catalog editor or directly as JSON. To add a language,
add its translations to the catalog and its code to `CFBundleLocalizations` in
`Resources/Info.plist`.

## Development hooks

These work in release builds too; they exist to check the app without clicking through it.

- `TABULA_SNAPSHOT_DIR=<dir>`: every 3 seconds, saves a PNG of each open window into `<dir>`
  (used to verify the UI without screen-recording permission). The images contain whatever
  data is on screen.
- `TABULA_IMPORT_FILE=<TablePlus export>` and `TABULA_IMPORT_PASSWORD=<password>`:
  import a TablePlus export at launch, skipping servers already saved. The password sits in
  the environment, so use it only on your own machine.
- `TABULA_CONNECTIONS_FILE=<file.json>`: use this file instead of
  `~/Library/Application Support/Tabula/connections.json`.
- `--connect "<name>"` (repeatable) opens saved connections at launch; `--table <name>` then
  opens that table, `--query "<sql>"` opens it in an editor and `--run` executes it.

On Intel Macs, or with libpq outside Homebrew, set `LIBPQ_PREFIX` to libpq's prefix before
building (Intel Homebrew: `LIBPQ_PREFIX=/usr/local/opt/libpq`). On a macOS newer than `LSMinimumSystemVersion`, `./scripts/build-app.sh` warns that the
bundled dylibs need that newer macOS (the result may not run on older Macs); in CI the same check
fails the build.

## Known limitations

- **One connection per window.** All tabs and the sidebar share one database connection: a long
  query makes the others wait, Cancel stops whatever is running, and Tabula's own catalog queries
  run inside a transaction you opened.
- **Results live in memory.** The row limit defaults to "no limit", and a huge result can use a
  lot of memory.
- **No certificate verification for PostgreSQL.** The SSL modes are disable, prefer and require;
  `verify-ca`/`verify-full` from URLs or TablePlus become `require`, with a warning.
  Aurora DSQL is always verified (`verify-full`).
- **Unsigned releases.** Releases are ad-hoc signed and not notarized: macOS may ask again for
  Keychain access after every update, and the app runs on Apple Silicon only. libpq, OpenSSL
  and Kerberos are bundled, so their security fixes need a new Tabula release.
- **Pre-connect scripts are stored in plain text** in `connections.json` and `tunnels.json`:
  do not put secrets in them.
- **Table pages are not stably ordered.** Pages use `LIMIT`/`OFFSET` without `ORDER BY` unless
  you sort a column, so rows can repeat or move between pages when the table changes.
- **Nested block comments** (`/* /* */ */`) are not understood by the statement splitter.
- **`connections.json` is all-or-nothing.** If any entry cannot be read (for example a file
  written by a newer version), no connection loads; saving is refused, so nothing is lost.
