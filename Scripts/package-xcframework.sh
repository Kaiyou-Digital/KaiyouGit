#!/bin/bash
# Usage: package-xcframework.sh <dir>. Zips <dir>/CLibGit2.xcframework and prints only its checksum.
set -euo pipefail
dir=${1:?usage: package-xcframework.sh <dir>}
zip="$dir/CLibGit2.xcframework.zip"
rm -f "$zip"
ditto -c -k --keepParent "$dir/CLibGit2.xcframework" "$zip"
swift package compute-checksum "$zip"
