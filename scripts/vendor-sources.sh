#!/bin/sh
# Copies the third-party sources this app is built from into the package:
#   UxPlay's AirPlay protocol library (GPL-3.0)  -> Sources/CAirPlay/uxplay
#   libplist (LGPL-2.1)                           -> Sources/CPlist
# Run it again with newer checkouts to update. Usage: vendor-sources.sh <UxPlay checkout> <libplist checkout>
set -eu
UX="$(cd "$1" && pwd)"
PL="$(cd "$2" && pwd)"
cd "$(dirname "$0")/.."

A=Sources/CAirPlay/uxplay
P=Sources/CPlist
rm -rf "$A" "$P/src" "$P/libcnary" "$P/include"
mkdir -p "$A/playfair" "$A/fairplay_v2" "$A/llhttp" "$A/dns_sd" \
    "$P/src" "$P/libcnary/include" "$P/include/plist" ThirdParty/licenses

cp "$UX"/lib/*.c "$UX"/lib/*.h "$A/"
cp "$UX"/lib/playfair/*.c "$UX"/lib/playfair/*.h "$A/playfair/"
cp "$UX"/lib/fairplay_v2/*.c "$UX"/lib/fairplay_v2/*.h "$A/fairplay_v2/"
cp "$UX"/lib/llhttp/*.c "$UX"/lib/llhttp/*.h "$A/llhttp/"
# Bonjour backend; the alternative mdnsd backend is not used on macOS.
cp "$UX"/lib/dns_sd/*.c "$A/dns_sd/"

# C sources only; the C++ wrapper classes are not needed.
cp "$PL"/src/*.c "$PL"/src/*.h "$P/src/"
cp "$PL"/libcnary/node.c "$PL"/libcnary/node_list.c "$P/libcnary/"
cp "$PL"/libcnary/include/*.h "$P/libcnary/include/"
cp "$PL"/include/plist/plist.h "$P/include/plist/"

cp "$UX/LICENSE" ThirdParty/licenses/UxPlay-GPL-3.0.txt
cp "$UX/lib/llhttp/LICENSE-MIT" ThirdParty/licenses/llhttp-MIT.txt
cp "$UX/lib/playfair/LICENSE.md" ThirdParty/licenses/playfair-LICENSE.md
cp "$PL/COPYING.LESSER" ThirdParty/licenses/libplist-LGPL-2.1.txt
cp "$PL/libcnary/COPYING" ThirdParty/licenses/libcnary-COPYING.txt

describe() {
    (cd "$1" && git log -1 --format='%H %ad' --date=short 2>/dev/null) || echo "unknown"
}
{
    echo "UxPlay   https://github.com/FDH2/UxPlay                  $(describe "$UX")"
    echo "libplist https://github.com/libimobiledevice/libplist    $(describe "$PL")"
} > ThirdParty/VERSIONS.txt
echo "vendored: $(find "$A" -name '*.c' | wc -l | tr -d ' ') UxPlay C files, $(find "$P" -name '*.c' | wc -l | tr -d ' ') libplist C files"
