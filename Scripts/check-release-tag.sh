#!/bin/bash
# Usage: check-release-tag.sh <X.Y.Z> [remote]. Exits 1 unless the version is X.Y.Z and tag vX.Y.Z is free locally and on the remote.
# Also exits non-zero when the remote cannot be queried (a failed lookup must never read as "tag is free").
set -euo pipefail
version=${1:?usage: check-release-tag.sh X.Y.Z [remote]}
remote=${2:-origin}
if ! [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Version '$version' is not X.Y.Z" >&2
  exit 1
fi
tag="v$version"
if git rev-parse -q --verify "refs/tags/$tag" > /dev/null; then
  echo "Tag $tag already exists locally" >&2
  exit 1
fi
remote_tags=$(git ls-remote --tags "$remote" "refs/tags/$tag") # assignment, so set -e fires if ls-remote fails
if [ -n "$remote_tags" ]; then
  echo "Tag $tag already exists on $remote" >&2
  exit 1
fi
