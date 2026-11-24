#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

sh scripts/check-repository.sh
MIN_MACOS="$(plutil -extract LSMinimumSystemVersion raw -o - App/Info.plist)"
MACOS_VERSION="$(sw_vers -productVersion)"
if [ "$(uname -m)" != arm64 ] || [ "${MACOS_VERSION%%.*}" -lt "${MIN_MACOS%%.*}" ]; then
  echo "CI requires Apple silicon and macOS $MIN_MACOS or later." >&2
  exit 1
fi

xcodebuild -version
swift --version
OPENSSL_PREFIX="${OPENSSL_PREFIX:-$(brew --prefix openssl@3)}"
SWIFTPM_SCRATCH_PATH="${SWIFTPM_SCRATCH_PATH:-build/ci/swiftpm}"
APP_OUTPUT_DIR="${APP_OUTPUT_DIR:-build/ci}"
export OPENSSL_PREFIX SWIFTPM_SCRATCH_PATH APP_OUTPUT_DIR
xcrun lipo -verify_arch arm64 "$OPENSSL_PREFIX/lib/libcrypto.a"
if [ -x "$OPENSSL_PREFIX/bin/openssl" ]; then
  "$OPENSSL_PREFIX/bin/openssl" version
fi
plutil -lint App/Info.plist App/*.lproj/InfoPlist.strings
swift test --scratch-path "$SWIFTPM_SCRATCH_PATH"
RELEASE_SIGNING=0 CODESIGN_IDENTITY=- sh scripts/make-app.sh release

APP="$APP_OUTPUT_DIR/AirPlayViewer.app"
BIN="$APP/Contents/MacOS/AirPlayViewer"
RESOURCES="$APP/Contents/Resources"
plutil -lint "$APP/Contents/Info.plist"
test "$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")" = "$(sh scripts/version.sh)"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - App/Info.plist)"
test "$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")" = "$BUNDLE_ID"
test "$(xcrun vtool -show-build "$BIN" | awk '$1 == "minos" { print $2 }')" = "$MIN_MACOS"
for locale in en zh-Hans; do
  plutil -lint "$RESOURCES/$locale.lproj/InfoPlist.strings" \
    "$RESOURCES/AirPlayViewer_AirPlayViewer.bundle/Contents/Resources/$locale.lproj/Localizable.strings"
done
for license in ThirdParty/licenses/*; do
  cmp "$license" "$RESOURCES/Licenses/${license##*/}"
done
cmp "${OPENSSL_LICENSE_FILE:-$OPENSSL_PREFIX/LICENSE.txt}" "$RESOURCES/Licenses/OpenSSL-Apache-2.0.txt"
LINKS="$(otool -L "$BIN")"
printf '%s\n' "$LINKS"
case "$LINKS" in
  *libcrypto*.dylib*|*/opt/homebrew/*|*/usr/local/Cellar/*)
    echo "The app unexpectedly links a Homebrew library or dynamic OpenSSL." >&2
    exit 1
    ;;
esac
codesign --verify --deep --strict --test-requirement "=identifier \"$BUNDLE_ID\"" "$APP"
echo "Verified local package: $APP"
RELEASE_SIGNING=0 sh scripts/make-dmg.sh "$APP" "$APP_OUTPUT_DIR"
