#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
VERSION="$(sh scripts/version.sh)"
BUILD_NUMBER="${GITHUB_RUN_NUMBER:-1}"
OPENSSL_PREFIX="${OPENSSL_PREFIX:-$(brew --prefix openssl@3)}"
export OPENSSL_PREFIX
OPENSSL_LICENSE_FILE="${OPENSSL_LICENSE_FILE:-$OPENSSL_PREFIX/LICENSE.txt}"
test -s "$OPENSSL_LICENSE_FILE"
if [ -n "${SWIFTPM_SCRATCH_PATH:-}" ]; then
    set -- --scratch-path "$SWIFTPM_SCRATCH_PATH"
else
    set --
fi
swift build -c "$CONFIG" "$@"
BIN_DIR="$(swift build -c "$CONFIG" "$@" --show-bin-path)"
OUTPUT_DIR="${APP_OUTPUT_DIR:-build}"
mkdir -p "$OUTPUT_DIR"
TMP_BUILD="$(mktemp -d "$OUTPUT_DIR/.AirPlayViewer.XXXXXX")"
trap 'rm -rf "$TMP_BUILD"' 0
APP="$TMP_BUILD/AirPlayViewer.app"
TMP_ICON="$TMP_BUILD/icon"
mkdir "$TMP_ICON"
MIN_MACOS="$(plutil -extract LSMinimumSystemVersion raw -o - App/Info.plist)"
xcrun actool --compile "$TMP_ICON" --platform macosx --minimum-deployment-target "$MIN_MACOS" \
    --app-icon AppIcon --output-partial-info-plist "$TMP_ICON/IconInfo.plist" \
    --output-format human-readable-text --warnings --errors App/AppIcon.icon
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/AirPlayViewer" "$APP/Contents/MacOS/AirPlayViewer"
cp -R "$BIN_DIR/AirPlayViewer_AirPlayViewer.bundle" "$APP/Contents/Resources/"
cp "$TMP_ICON/AppIcon.icns" "$TMP_ICON/Assets.car" "$APP/Contents/Resources/"
cp App/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Merge $TMP_ICON/IconInfo.plist" "$APP/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -insert CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
cp -R App/*.lproj "$APP/Contents/Resources/"
cp -R ThirdParty/licenses "$APP/Contents/Resources/Licenses"
cp ThirdParty/VERSIONS.txt "$APP/Contents/Resources/Licenses/VERSIONS.txt"
cp "$OPENSSL_LICENSE_FILE" "$APP/Contents/Resources/Licenses/OpenSSL-Apache-2.0.txt"
if [ -s LICENSE ]; then
    cp LICENSE "$APP/Contents/Resources/Licenses/AirPlayViewer-LICENSE.txt"
fi
# Prefer a stable local development identity to preserve Local Network permission between builds.
if [ "${CODESIGN_IDENTITY+x}" = x ]; then
    IDENTITY="${CODESIGN_IDENTITY:?Use '-' explicitly for ad-hoc signing}"
else
    IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
    IDENTITY="${IDENTITY:--}"
fi
if [ "${RELEASE_SIGNING:-0}" = 1 ]; then
    case "$IDENTITY" in
        'Developer ID Application: '*) ;;
        *) echo "Release signing requires a Developer ID Application identity." >&2; exit 1 ;;
    esac
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
else
    codesign --force --sign "$IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"

DESTINATION="$OUTPUT_DIR/AirPlayViewer.app"
rm -rf "$DESTINATION"
mv "$APP" "$DESTINATION"
echo "Built $DESTINATION ($VERSION, not yet notarized)"
