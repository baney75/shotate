#!/bin/bash
# Prints the name of a local code-signing identity, creating it on first use, and the keychain that
# holds it. macOS ties the Screen Recording permission to the app's signature. An ad-hoc signature
# changes on every build, so macOS forgot the permission after each update; a stable local
# certificate keeps it. The key lives in its own keychain under Application Support. It never
# touches the login keychain and is not trusted for anything else.
#   scripts/signing-identity.sh   ->  "Snapmark Local Signing<TAB>/path/to/snapmark-signing.keychain-db"
set -euo pipefail
NAME="Snapmark Local Signing"
DIR="$HOME/Library/Application Support/Snapmark/Signing"
KC="$DIR/snapmark-signing.keychain-db"
PASS_FILE="$DIR/keychain-password"

if [ ! -f "$KC" ] || ! security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$NAME"; then
  mkdir -p "$DIR" && chmod 700 "$DIR"
  rm -f "$KC"
  umask 077
  head -c 24 /dev/urandom | base64 > "$PASS_FILE"
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/cfg" <<CFG
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CFG
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 7300 \
    -config "$TMP/cfg" >/dev/null 2>&1
  P12PASS=$(head -c 12 /dev/urandom | base64)
  openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" \
    -passout "pass:$P12PASS" >/dev/null 2>&1 \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" \
    -passout "pass:$P12PASS" >/dev/null 2>&1
  security create-keychain -p "$(cat "$PASS_FILE")" "$KC"
  security set-keychain-settings "$KC"   # no auto-lock timeout
  security unlock-keychain -p "$(cat "$PASS_FILE")" "$KC"
  security import "$TMP/id.p12" -k "$KC" -P "$P12PASS" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k "$(cat "$PASS_FILE")" "$KC" >/dev/null
fi
security unlock-keychain -p "$(cat "$PASS_FILE")" "$KC"
printf '%s\t%s\n' "$NAME" "$KC"
