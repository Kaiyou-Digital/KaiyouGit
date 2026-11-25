#!/bin/bash
# Usage: set-package-binary.sh <url> <checksum>. Rewrites only the `url:` and `checksum:` lines of Package.swift.
set -euo pipefail
url=${1:?usage: set-package-binary.sh URL CHECKSUM}
sum=${2:?usage: set-package-binary.sh URL CHECKSUM}
pkg="${PACKAGE_FILE:-$(cd "$(dirname "$0")/.." && pwd)/Package.swift}"
sed -E -i '' \
  -e "s|^( *url: \")[^\"]*(\",?)\$|\\1$url\\2|" \
  -e "s|^( *checksum: \")[^\"]*(\",?)\$|\\1$sum\\2|" "$pkg"
