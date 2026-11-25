#!/bin/bash
# Usage: verify-package-rewrite.sh <url> <checksum>. After set-package-binary.sh: fails unless exactly the url and
# checksum lines of Package.swift changed, and the manifest parses in its remote form with the new values.
set -euo pipefail
url=${1:?usage: verify-package-rewrite.sh URL CHECKSUM}
sum=${2:?usage: verify-package-rewrite.sh URL CHECKSUM}
git diff Package.swift
[ "$(git diff --numstat | awk '{print $1 "/" $2 "/" $3}')" = "2/2/Package.swift" ] || { echo "Unexpected diff" >&2; git diff --stat >&2; exit 1; }
other=$(git diff -U0 Package.swift | grep -E '^[-+] ' | grep -vE '^[-+] +(url|checksum): ' || true)
[ -z "$other" ] || { echo "Changed a line other than url or checksum: $other" >&2; exit 1; }
manifest=$(env -u KAIYOUGIT_LOCAL_XCFRAMEWORK swift package dump-package)
grep -qF "\"$url\"" <<< "$manifest" || { echo "dump-package lacks the new URL" >&2; exit 1; }
grep -qF "\"$sum\"" <<< "$manifest" || { echo "dump-package lacks the new checksum" >&2; exit 1; }
