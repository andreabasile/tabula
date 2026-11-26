# Tabula

A macOS database client modeled on TablePlus, for PostgreSQL and Amazon Aurora DSQL.
The interface is available in English, Italian, French and German and follows the macOS system language.

With DSQL the password is an IAM token generated with the AWS CLI and the local credentials
of the chosen profile (SSO, assume-role, keys). Tabula renews it on its own and recreates the
connection before DSQL's 60-minute limit or when the server closes it.

## Installation

```bash
brew install --cask andreabasile/tap/tabula
```

Apple Silicon only, macOS 15+. The app is ad-hoc signed and not notarized: the cask removes the
quarantine attribute after installation, otherwise Gatekeeper would block it from opening.
libpq is bundled in the app. Aurora DSQL connections need the AWS CLI v2 (for example
`/opt/homebrew/bin/aws` or `/usr/local/bin/aws`).
At launch, Tabula checks GitHub for a newer release and, if there is one, shows a one-time notice
with the update command (`brew upgrade --cask tabula`).

## How the DSQL token works

- `CachedTokenProvider` reuses the token until less than a minute remains before it expires;
  the token is only needed to open the connection, which then stays valid.
- `ManagedSession` recreates the connection after 55 minutes (like the AWS connectors),
  and when it drops: reads are retried, writes are not.
- If DSQL rejects a cached token, it generates a new one and retries once.
- The status bar shows the token's validity, how long the connection has been open,
  and how many reconnections have occurred; "Reconnect" (⇧⌘R) forces a new token and connection.

## Pre-connection script (tunnel)

Each connection can have a script, saved with it, that Tabula runs in a zsh login shell before
connecting, for example `bash ~/scripts/db-tunnel-prod.sh` for an SSM tunnel.

- "Opens a tunnel" (default): the script may keep running; Tabula only launches it if
  host:port is not already responding, waits for it to respond (30 s by default), relaunches it
  when the tunnel drops and the connection must be recreated, and kills the whole process tree
  when the last window using it closes or when the app quits. Connections on the same port share the tunnel.
- Otherwise the script must exit successfully on every connection (e.g. `aws sso login`).

If it fails, the error shows the last lines of its output. The TablePlus import carries over
their `StartupBashScript`.

## Import from TablePlus

"Import from TablePlus…" in the welcome window reads the file from File › Export Connections
(encrypted with RNCryptor v3 using the password chosen at export), shows a preview, and imports groups,
tags, SSL, safe mode and passwords (into the Keychain). Connections that already exist, with the same
host/port/user/database, are left unselected.

## Multiple connections

As in TablePlus, open connections sit in the column on the left of the window, with the
icon colored by tag; ⌘K opens another one, ⌘1…⌘9 switch between them.
For PostgreSQL, ⌘D switches database on the same server. The box in the middle of the toolbar is
colored by tag; clicking it shows host, user, token and the Reconnect/Disconnect buttons.

## Shortcuts

⌘K open connection · ⌘1…⌘9 switch connection · ⌘D open database · ⇧⌘0 manage connections · ⌘T new query ·
⌘↩ run current statement or selection · ⇧⌘↩ run all · ⌘S save changes · ⌘F filters ·
⌘P find table · ⌘R refresh · ⇧⌘R reconnect · ⇧⌘C console · ⌘] row detail

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for requirements, build and test commands, development hooks
and known limitations. Security issues: [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
