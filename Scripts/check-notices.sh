#!/bin/bash
# Exits 1, naming the variable, if a source version pinned in build-xcframework.sh is missing from the notices, or
# if a pinned commit (OPENSSL_SHA, SSH2_SHA, LG2_SHA) is not 40 lowercase hex digits.
set -euo pipefail
# Expects pin lines in build-xcframework.sh of exactly the form NAME=value at the start of a line
# (e.g. LG2_TAG=v1.9.7, no quotes, no spaces, no trailing comment). The *_TAG value must appear as a whole word.
HERE="$(cd "$(dirname "$0")/.." && pwd)"
NOTICES_FILE="${NOTICES_FILE:-$HERE/THIRD_PARTY_NOTICES.md}"
BUILD_SCRIPT="${BUILD_SCRIPT:-$HERE/Scripts/build-xcframework.sh}"
status=0
for var in OPENSSL_SHA SSH2_SHA LG2_SHA; do
  value=$(sed -n "s/^$var=//p" "$BUILD_SCRIPT")
  if ! [[ $value =~ ^[0-9a-f]{40}$ ]]; then
    echo "$var (${value:-unset}) is not a 40-digit commit SHA" >&2
    status=1
  fi
done
for var in OPENSSL_TAG SSH2_TAG LG2_TAG; do
  value=$(sed -n "s/^$var=//p" "$BUILD_SCRIPT")
  if [ -z "$value" ] || ! grep -qFw -- "$value" "$NOTICES_FILE"; then
    echo "$var (${value:-unset}) is missing from $NOTICES_FILE" >&2
    status=1
  fi
done
exit $status
