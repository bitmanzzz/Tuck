#!/usr/bin/env bash
# Creates a self-signed code signing identity for Tuck in its own keychain.
#
# Why: macOS ties Accessibility and Screen Recording grants to an app's code
# signature. Ad-hoc signatures change on every build, so users would have to
# grant permissions again after each update. A stable self-signed certificate
# keeps the grants. (It does not replace Apple notarization; Gatekeeper still
# asks users to confirm the first launch.)
#
# Output (default ~/.tuck-signing, override with TUCK_SIGNING_DIR):
#   tuck.p12, p12-password      upload these as GitHub secrets for CI releases
#   tuck.keychain-db, keychain-password
set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
DIR="${TUCK_SIGNING_DIR:-$HOME/.tuck-signing}"
NAME="Tuck Self-Signed"
mkdir -p "$DIR"
chmod 700 "$DIR"
cd "$DIR"

if [[ ! -f tuck.p12 ]]; then
  cat > cert.cnf <<CNF
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
  openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 7300 -config cert.cnf
  openssl rand -hex 16 > p12-password
  # -legacy keeps the PKCS#12 readable by macOS `security import`.
  openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -name "$NAME" \
    -out tuck.p12 -passout "file:p12-password"
  rm -f key.pem cert.cnf
  chmod 600 tuck.p12 p12-password
fi

"$SCRIPTS/import-signing-identity.sh" "$DIR/tuck.p12" "$(cat p12-password)" "$DIR/tuck.keychain-db"
echo
echo "Signing identity ready in $DIR"
echo "For GitHub releases, add these repository secrets:"
echo "  SIGNING_P12_BASE64   = \$(base64 -i $DIR/tuck.p12)"
echo "  SIGNING_P12_PASSWORD = \$(cat $DIR/p12-password)"
