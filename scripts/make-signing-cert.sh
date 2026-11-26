#!/bin/bash
# Creates the self-signed certificate that signs Tabula releases. Run it ONCE, on your own Mac:
# it imports the identity into the login keychain (the backup, also used by local builds) and
# uploads it to the GitHub Actions secrets that release.yml reads. A stable certificate keeps the
# app's designated requirement the same across releases, so macOS does not ask again for Keychain
# access to the saved passwords after every update. It prints no key, .p12 or password.
# Usage: ./scripts/make-signing-cert.sh [--force] [--no-upload] [--keychain <path>]
set -euo pipefail
umask 077

NAME="Tabula Release Signing"
REPO=andreabasile/tabula
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
FORCE=""
UPLOAD=1
while (($#)); do
    case "$1" in
        --force) FORCE=1 ;;
        --no-upload) UPLOAD="" ;;
        --keychain) KEYCHAIN="${2:?--keychain needs a path}"; shift ;;
        *) echo "usage: $0 [--force] [--no-upload] [--keychain <path>]" >&2; exit 2 ;;
    esac
    shift
done

# Without -v: the certificate is self-signed, so find-identity never counts it as valid.
OLD=$(security find-identity -p codesigning "$KEYCHAIN" | sed -n "s/^ *[0-9]*) \([0-9A-F]*\) \"$NAME\".*/\1/p" | sort -u)
if [[ -n "$OLD" && -z "$FORCE" ]]; then
    echo "error: \"$NAME\" is already in $KEYCHAIN." >&2
    echo "A new certificate changes the app's identity: after the next release every user is asked" >&2
    echo "again for Keychain access to each saved password. Use --force only to replace a lost or" >&2
    echo "leaked certificate (or after a run that failed before uploading); it deletes the old one" >&2
    echo "from this keychain." >&2
    exit 1
fi
if [[ -n "$UPLOAD" ]]; then
    gh auth status >/dev/null 2>&1 || { echo "error: gh is not logged in (gh auth login)" >&2; exit 1; }
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<EOF
[req]
prompt = no
distinguished_name = dn
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
# /usr/bin/openssl is LibreSSL: its .p12 uses the legacy ciphers that `security import` accepts.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
P12_PASSWORD=$(/usr/bin/openssl rand -hex 32)
export P12_PASSWORD
/usr/bin/openssl pkcs12 -export -name "$NAME" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/cert.p12" -passout env:P12_PASSWORD

for hash in $OLD; do
    security delete-identity -Z "$hash" "$KEYCHAIN"
    echo "deleted the old identity $hash from $KEYCHAIN"
done
security import "$TMP/cert.p12" -k "$KEYCHAIN" -f pkcs12 -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null
echo "imported \"$NAME\" into $KEYCHAIN"

if [[ -n "$UPLOAD" ]]; then
    base64 -i "$TMP/cert.p12" | gh secret set TABULA_SIGNING_CERT_P12 -R "$REPO"
    printf '%s' "$P12_PASSWORD" | gh secret set TABULA_SIGNING_CERT_PASSWORD -R "$REPO"
    echo "uploaded TABULA_SIGNING_CERT_P12 and TABULA_SIGNING_CERT_PASSWORD to $REPO"
else
    echo "not uploaded (--no-upload)"
fi
/usr/bin/openssl x509 -in "$TMP/cert.pem" -noout -fingerprint -sha1
