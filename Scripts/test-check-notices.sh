#!/bin/bash
# Runs check-notices.sh against temp notices files; exits non-zero on any wrong result.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
tags=$(grep -E '^(OPENSSL_TAG|SSH2_TAG|LG2_TAG)=' "$HERE/Scripts/build-xcframework.sh" | sed 's/^[A-Z0-9_]*=//')
lg2=$(sed -n 's/^LG2_TAG=//p' "$HERE/Scripts/build-xcframework.sh")
fail=0
expect() { # name wanted-exit-code notices-file
  local got=0
  NOTICES_FILE="$3" "$HERE/Scripts/check-notices.sh" > /dev/null 2>&1 || got=1
  if [ "$got" != "$2" ]; then echo "FAIL: $1 (exit $got, wanted $2)" >&2; fail=1; else echo "ok: $1"; fi
}
echo "$tags" > "$T/all"
expect "all pins present" 0 "$T/all"
echo "$tags" | grep -vxF "$lg2" > "$T/missing"
expect "one pin missing" 1 "$T/missing"
echo "$tags" | sed "s/^$lg2\$/${lg2}1/" > "$T/longer"
expect "longer version does not satisfy pin" 1 "$T/longer"
: > "$T/empty"
expect "empty notices" 1 "$T/empty"
# A pinned commit must be 40 lowercase hex digits, and present.
expect_script() { # name build-script
  local got=0
  BUILD_SCRIPT="$2" NOTICES_FILE="$T/all" "$HERE/Scripts/check-notices.sh" > /dev/null 2>&1 || got=1
  if [ "$got" != 1 ]; then echo "FAIL: $1 accepted" >&2; fail=1; else echo "ok: $1 rejected"; fi
}
sed 's/^LG2_SHA=.*/LG2_SHA=abc123/' "$HERE/Scripts/build-xcframework.sh" > "$T/short-sha.sh"
expect_script "short SHA" "$T/short-sha.sh"
sed '/^SSH2_SHA=/d' "$HERE/Scripts/build-xcframework.sh" > "$T/no-sha.sh"
expect_script "missing SHA" "$T/no-sha.sh"
exit $fail
