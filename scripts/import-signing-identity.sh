#!/usr/bin/env bash
# Imports a .p12 signing identity into a dedicated keychain that codesign can use
# without prompts. Usage: import-signing-identity.sh <p12> <p12-password> <keychain-path>
set -euo pipefail
P12="$1"; P12_PASSWORD="$2"; KEYCHAIN="$3"
PASSWORD_FILE="${KEYCHAIN%.keychain-db}.password"

if [[ ! -f "$KEYCHAIN" ]]; then
  openssl rand -hex 16 > "$PASSWORD_FILE"
  chmod 600 "$PASSWORD_FILE"
  security create-keychain -p "$(cat "$PASSWORD_FILE")" "$KEYCHAIN"
  security set-keychain-settings "$KEYCHAIN"   # never auto-lock
fi
security unlock-keychain -p "$(cat "$PASSWORD_FILE")" "$KEYCHAIN"
security import "$P12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null 2>&1 || true
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$(cat "$PASSWORD_FILE")" "$KEYCHAIN" >/dev/null
security find-identity -p codesigning "$KEYCHAIN" | grep -q "Tuck Self-Signed" || {
  echo "error: identity not found in $KEYCHAIN" >&2
  exit 1
}
echo "Imported signing identity into $KEYCHAIN"
