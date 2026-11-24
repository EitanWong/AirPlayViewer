#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

APP="${1:-build/ci/AirPlayViewer.app}"
OUTPUT="${2:-build/ci}"
VERSION="$(sh scripts/version.sh)"
NAME="AirPlayViewer-$VERSION-arm64.dmg"
test "$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")" = "$VERSION"
xcrun lipo -verify_arch arm64 "$APP/Contents/MacOS/AirPlayViewer"
codesign --verify --deep --strict "$APP"

mkdir -p "$OUTPUT"
WORK="$(mktemp -d "$OUTPUT/.AirPlayViewer-dmg.XXXXXX")"
MOUNTED=0
cleanup() {
  if [ "$MOUNTED" = 1 ]; then
    hdiutil detach "$WORK/mount" >&2 || return
  fi
  rm -rf "$WORK"
}
trap cleanup 0
mkdir "$WORK/image" "$WORK/mount"

notarize() {
  response="$(xcrun notarytool submit "$1" --wait --output-format json \
    --key "${NOTARY_KEY_FILE:?}" --key-id "${APPLE_NOTARY_KEY_ID:?}" --issuer "${APPLE_NOTARY_ISSUER_ID:?}")"
  printf '%s\n' "$response"
  printf '%s\n' "$response" | jq -e '.status == "Accepted"' >/dev/null
}

ditto "$APP" "$WORK/image/AirPlayViewer.app"
ln -s /Applications "$WORK/image/Applications"
if [ "${RELEASE_SIGNING:-0}" = 1 ]; then
  SIGNED_APP="$WORK/image/AirPlayViewer.app"
  ditto -c -k --keepParent "$SIGNED_APP" "$WORK/AirPlayViewer.zip"
  notarize "$WORK/AirPlayViewer.zip"
  xcrun stapler staple "$SIGNED_APP"
  xcrun stapler validate "$SIGNED_APP"
fi

DMG="$WORK/$NAME"
hdiutil create -srcfolder "$WORK/image" -volname AirPlayViewer -format UDZO "$DMG"
if [ "${RELEASE_SIGNING:-0}" = 1 ]; then
  codesign --sign "${CODESIGN_IDENTITY:?}" --timestamp "$DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  codesign --verify --strict "$DMG"
  spctl --assess --type open --context context:primary-signature "$DMG"
fi

hdiutil verify "$DMG"
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$WORK/mount"
MOUNTED=1
test "$(readlink "$WORK/mount/Applications")" = /Applications
codesign --verify --deep --strict "$WORK/mount/AirPlayViewer.app"
if [ "${RELEASE_SIGNING:-0}" = 1 ]; then
  spctl --assess --type execute "$WORK/mount/AirPlayViewer.app"
fi
hdiutil detach "$WORK/mount"
MOUNTED=0
(cd "$WORK" && shasum -a 256 "$NAME" > "$NAME.sha256")
mv "$DMG" "$OUTPUT/$NAME"
mv "$WORK/$NAME.sha256" "$OUTPUT/$NAME.sha256"
echo "Verified DMG: $OUTPUT/$NAME"
