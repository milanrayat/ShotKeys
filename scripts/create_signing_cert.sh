#!/usr/bin/env bash
# One-time setup: creates a self-signed code-signing certificate called "ShotKeys Local Signing"
# in your login keychain, so every build has the same signature and macOS remembers the
# Input Monitoring permission across rebuilds. Run it yourself; it asks for your password to
# trust the certificate for code signing. Not needed if you have an Apple Development certificate.
set -euo pipefail

NAME="ShotKeys Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "\"$NAME\" already exists in your login keychain. Nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/identity.p12" -passout pass:shotkeys

security import "$TMP/identity.p12" -k "$KEYCHAIN" -P shotkeys -T /usr/bin/codesign
echo "Trusting the certificate for code signing (macOS will ask for your password)..."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

if ! security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "ERROR: \"$NAME\" is not a valid code-signing identity yet." >&2
  security find-identity -p codesigning | grep "$NAME" >&2 || echo "(certificate not found in keychain)" >&2
  exit 1
fi

echo "Done. Rebuild with scripts/build.sh; it will pick up \"$NAME\" automatically."
echo "Grant Input Monitoring once more after that first signed build; it then sticks."
