#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

case "${CODESIGN_IDENTITY:?}" in
  'Developer ID Application: '*) ;;
  *) echo "Expected a Developer ID Application identity." >&2; exit 1 ;;
esac
test -s LICENSE || { echo "An approved root LICENSE is required to release." >&2; exit 1; }
umask 077
WORK="$(mktemp -d "${RUNNER_TEMP:-/tmp}/AirPlayViewer-signing.XXXXXX")"
KEYCHAIN="$WORK/release.keychain-db"
trap 'security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || :; rm -rf "$WORK"' 0
PASSWORD="$(openssl rand -hex 32)"
printf '%s' "${APPLE_CERT_P12_B64:?}" | base64 -D > "$WORK/certificate.p12"
printf '%s' "${APPLE_NOTARY_KEY_P8_B64:?}" | base64 -D > "$WORK/AuthKey_${APPLE_NOTARY_KEY_ID:?}.p8"
NOTARY_KEY_FILE="$WORK/AuthKey_$APPLE_NOTARY_KEY_ID.p8"
export NOTARY_KEY_FILE
security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 7200 "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$WORK/certificate.p12" -k "$KEYCHAIN" -P "${APPLE_CERT_PASSWORD:?}" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN"
# Only run on an ephemeral release runner.
security list-keychains -d user -s "$KEYCHAIN"
unset APPLE_CERT_P12_B64 APPLE_CERT_PASSWORD APPLE_NOTARY_KEY_P8_B64

export RELEASE_SIGNING=1 APP_OUTPUT_DIR=build/release SWIFTPM_SCRATCH_PATH=build/release/swiftpm
sh scripts/make-app.sh release
sh scripts/make-dmg.sh "$APP_OUTPUT_DIR/AirPlayViewer.app" "$APP_OUTPUT_DIR"
