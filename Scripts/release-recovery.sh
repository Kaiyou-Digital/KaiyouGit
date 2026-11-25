#!/bin/bash
# Usage: release-recovery.sh <X.Y.Z> [remote]. Looks at the remote tag and the GitHub release for vX.Y.Z and prints
# the recipe that fits that state. Env: RUN_ID (default $GITHUB_RUN_ID, else a placeholder), REPO (default
# $GITHUB_REPOSITORY, else Kaiyou-Digital/KaiyouGit), GH (the gh command, so tests can stub it).
# Fails (non-zero, nothing printed as advice) when the remote or the release lookup itself fails.
set -euo pipefail
version=${1:?usage: release-recovery.sh X.Y.Z [remote]}
remote=${2:-origin}
tag="v$version"
run=${RUN_ID:-${GITHUB_RUN_ID:-<run-id>}}
repo=${REPO:-${GITHUB_REPOSITORY:-Kaiyou-Digital/KaiyouGit}}
gh_cmd=${GH:-gh}

remote_tags=$(git ls-remote --tags "$remote" "refs/tags/$tag") # assignment, so set -e fires if ls-remote fails
have_tag=false
[ -z "$remote_tags" ] || have_tag=true

have_release=false
if out=$("$gh_cmd" release view "$tag" -R "$repo" 2>&1); then
  have_release=true
elif ! grep -qi 'not found' <<< "$out"; then
  echo "Could not look up release $tag: $out" >&2
  exit 1
fi

# The checks every recipe starts with: fetch the build's own bytes and prove they match the tagged manifest.
verify=$(
  cat << 'EOF'
git fetch --tags origin   # in a clone of @REPO@
gh run download @RUN@ -n release-assets -D /tmp/ra -R @REPO@   # artifacts expire 30 days after the run
want=$(git show @TAG@:Package.swift | sed -n 's/^ *checksum: "\(.*\)".*/\1/p')
[ "$(swift package compute-checksum /tmp/ra/CLibGit2.xcframework.zip)" = "$want" ] || { echo "MISMATCH: wrong run id?" >&2; exit 1; }
EOF
)

if ! $have_tag && ! $have_release; then
  echo "## $tag: nothing was pushed"
  echo
  echo "No tag and no release exist, so it is safe to re-run the workflow."
  exit 0
fi

echo "## $tag is incomplete"
echo
if $have_tag && ! $have_release; then
  echo "The tag exists but there is no release. Do not rebuild (the checksum would differ). Use the run that built the tagged commit (this run is $run):"
  echo '```'
  echo "$verify"
  echo "gh release create @TAG@ --verify-tag --title \"KaiyouGit $version\" --notes-file /tmp/ra/release-notes.md /tmp/ra/CLibGit2.xcframework.zip /tmp/ra/THIRD_PARTY_NOTICES.md -R @REPO@"
  echo '```'
elif $have_tag; then
  echo "The tag and the release exist, but the asset may be missing or wrong (often just a failed download). Use the run that built the tagged commit (this run is $run):"
  echo '```'
  echo "$verify"
  echo "gh release upload @TAG@ /tmp/ra/CLibGit2.xcframework.zip /tmp/ra/THIRD_PARTY_NOTICES.md --clobber -R @REPO@"
  echo 'd=$(mktemp -d); gh release download @TAG@ -p CLibGit2.xcframework.zip -D "$d" -R @REPO@'
  echo '[ "$(swift package compute-checksum "$d/CLibGit2.xcframework.zip")" = "$want" ] || { echo "UPLOADED ASSET DIFFERS" >&2; exit 1; }'
  echo '```'
else
  echo "A release exists but the tag does not on $remote. Inspect by hand: the workflow never creates a release without its tag."
fi | sed -e "s|@TAG@|$tag|g" -e "s|@REPO@|$repo|g" -e "s|@RUN@|$run|g"
