#!/bin/bash
# Usage: check-main-tip.sh <sha> [remote]. Exits 1 unless HEAD and the remote's main are both exactly <sha>,
# i.e. nothing has landed on main since the release was built. Run before any push.
set -euo pipefail
base=${1:?usage: check-main-tip.sh SHA [remote]}
remote=${2:-origin}
git fetch -q "$remote" main
tip=$(git rev-parse FETCH_HEAD)
head=$(git rev-parse HEAD)
if [ "$tip" != "$base" ] || [ "$head" != "$base" ]; then
  echo "main moved since the build (built $base, remote main $tip, checkout $head); nothing was pushed" >&2
  exit 1
fi
