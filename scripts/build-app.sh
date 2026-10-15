#!/usr/bin/env bash
# Builds Tuck.app into build/. Universal (arm64 + x86_64) by default.
#   VERSION=0.1.0 BUILD=1        version strings
#   ARCHS="arm64"                build a single architecture (faster)
#   SIGN_KEYCHAIN=path           keychain holding "Tuck Self-Signed"
#                                (default: ~/.tuck-signing/tuck.keychain-db if present,
#                                 created by scripts/setup-signing.sh; otherwise ad hoc)
#   PACKAGE=1                    also write dist/Tuck-<version>.zip
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"
ARCHS="${ARCHS:-arm64 x86_64}"
SIGN_KEYCHAIN="${SIGN_KEYCHAIN:-$HOME/.tuck-signing/tuck.keychain-db}"
APP="build/Tuck.app"

binaries=()
for arch in $ARCHS; do
  swift build -c release --arch "$arch" --product Tuck
  binaries+=(".build/$arch-apple-macosx/release/Tuck")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/Tuck"
strip -x "$APP/Contents/MacOS/Tuck"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"

if [[ -f "$SIGN_KEYCHAIN" ]]; then
  security unlock-keychain -p "$(cat "${SIGN_KEYCHAIN%.keychain-db}.password")" "$SIGN_KEYCHAIN"
  # codesign only finds identities in the search list; add the keychain briefly.
  read -r -a ORIGINAL_KEYCHAINS <<< "$(security list-keychains -d user | tr -d '"' | xargs)"
  trap 'security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}"' EXIT
  security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" "$SIGN_KEYCHAIN"
  codesign --force --sign "Tuck Self-Signed" --keychain "$SIGN_KEYCHAIN" --timestamp=none "$APP"
  security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}"
  trap - EXIT
else
  echo "warning: no signing keychain, signing ad hoc (permissions reset on every build)" >&2
  codesign --force --sign - --timestamp=none "$APP"
fi
codesign --verify --strict "$APP"

if [[ "${PACKAGE:-0}" == "1" ]]; then
  mkdir -p dist
  rm -f "dist/Tuck-$VERSION.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/Tuck-$VERSION.zip"
  echo "Packaged dist/Tuck-$VERSION.zip"
fi

echo "Built $APP ($(du -sh "$APP" | cut -f1))"
