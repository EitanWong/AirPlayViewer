#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

case $# in
  0) set -- "$(cat VERSION)" ;;
  1|2) ;;
  *) echo "Usage: version.sh [NEXT [PREVIOUS]]" >&2; exit 1 ;;
esac

if ! printf '%s\n' "$@" | LC_ALL=C awk -v count="$#" '
  $0 !~ /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/ { invalid = 1 }
  NR == 1 { split($0, nextVersion, ".") }
  NR == 2 { split($0, previous, ".") }
  END {
    if (invalid || NR != count) exit 1
    if (count == 1) exit 0
    for (i = 1; i <= 3; i++) {
      a = nextVersion[i]; b = previous[i]
      if (length(a) != length(b)) exit (length(a) < length(b))
      if ("x" a != "x" b) exit ("x" a < "x" b)
    }
    exit 1
  }
'; then
  echo "Expected a stable MAJOR.MINOR.PATCH version, strictly increasing when compared." >&2
  exit 1
fi
printf '%s\n' "$1"
