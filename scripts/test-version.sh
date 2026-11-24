#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

expect_pass() {
  if ! sh scripts/version.sh "$@" >/dev/null; then
    echo "Expected version check to pass: $*" >&2
    exit 1
  fi
}

expect_fail() {
  if sh scripts/version.sh "$@" >/dev/null 2>&1; then
    echo "Expected version check to reject: $*" >&2
    exit 1
  fi
}

expect_pass 0.1.0
expect_pass 0.1.1 0.1.0
expect_pass 0.10.0 0.9.9
expect_pass 1.0.0 0.99.99
expect_fail 0.1.0 0.1.0
expect_fail 0.1.9 0.2.0
expect_fail 0.01.0
expect_fail 0.1
expect_fail v0.1.0
expect_fail 0.1.0-rc.1
expect_fail "0.1.0
0.1.1"
