#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

for script in scripts/*.sh; do
  sh -n "$script"
done
sh scripts/test-version.sh
sh scripts/version.sh
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  tracked_ignored="$(git ls-files -ci --exclude-standard)"
  if [ -n "$tracked_ignored" ]; then
    printf 'Ignored files must not be tracked:\n%s\n' "$tracked_ignored" >&2
    exit 1
  fi
fi

catalog=Sources/AirPlayViewer/Resources/Localizable.xcstrings
jq -e '
  def complete:
    [.. | objects | .stringUnit? | select(. != null)]
    | length > 0 and all(.[]; .state == "translated" and (.value | type == "string" and length > 0));
  if .sourceLanguage != "en" or (.strings | length) == 0 then
    error("Expected a non-empty English source catalog")
  else
    [.strings | to_entries[] | select(.value.extractionState != "stale") |
     . as $entry | ("en", "zh-Hans") as $locale |
     select($entry.value.localizations[$locale] | complete | not) |
     "\($entry.key) (\($locale))"]
    | if length == 0 then true else error("Missing translations: " + join(", ")) end
  end
' "$catalog"

for locale in en zh-Hans; do
  test -s "App/$locale.lproj/InfoPlist.strings"
done

for license in UxPlay-GPL-3.0.txt llhttp-MIT.txt playfair-LICENSE.md libplist-LGPL-2.1.txt libcnary-COPYING.txt; do
  test -s "ThirdParty/licenses/$license"
done
