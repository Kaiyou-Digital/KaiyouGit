#!/bin/bash
# Self-check for the release scripts (check-release-tag, set-package-binary, check-main-tip and the atomic push),
# run against throwaway copies and repos. Exits 1 on the first failure.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
# Throwaway repos only; the real repo's signing config is untouched.
commit() { git -C "$1" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m "$2"; }

# set-package-binary: exactly the two lines change, and again on a second rewrite.
cp "$HERE/Package.swift" "$T/P.swift"
PACKAGE_FILE="$T/P.swift" "$HERE/Scripts/set-package-binary.sh" "https://x/y.zip" abc123
[ "$(diff "$HERE/Package.swift" "$T/P.swift" | grep -c '^>')" = 2 ] || fail "first rewrite changed other than 2 lines"
cp "$T/P.swift" "$T/P1.swift"
PACKAGE_FILE="$T/P.swift" "$HERE/Scripts/set-package-binary.sh" "https://x/z.zip" def456
[ "$(diff "$T/P1.swift" "$T/P.swift" | grep -c '^>')" = 2 ] || fail "second rewrite changed other than 2 lines"
grep -q 'url: "https://x/z.zip"' "$T/P.swift" || fail "url not set"
grep -q 'checksum: "def456"' "$T/P.swift" || fail "checksum not set"

# check-release-tag: bad version, local tag, remote tag, free tag, unreachable remote.
git init -q "$T/c"
commit "$T/c" init
git init -q --bare "$T/r.git"
check() { (cd "$T/c" && "$HERE/Scripts/check-release-tag.sh" "$@") 2> /dev/null; }
check 1.0 "$T/r.git" && fail "accepted 1.0"
check 1.0.0-rc1 "$T/r.git" && fail "accepted 1.0.0-rc1"
git -C "$T/c" tag v9.9.9
check 9.9.9 "$T/r.git" && fail "missed local tag"
git -C "$T/c" push -q "$T/r.git" v9.9.9
git -C "$T/c" tag -d v9.9.9 > /dev/null
check 9.9.9 "$T/r.git" && fail "missed remote tag"
check 9.9.8 "$T/r.git" || fail "rejected a free tag"
check 9.9.8 "$T/does-not-exist.git" && fail "treated an unreachable remote as a free tag"

# check-main-tip and the atomic push, with a remote whose main moves after the build.
git init -q --bare -b main "$T/o.git"
git clone -q "$T/o.git" "$T/w" 2> /dev/null
git -C "$T/w" checkout -q -b main
commit "$T/w" base
git -C "$T/w" push -q origin main
base=$(git -C "$T/w" rev-parse HEAD)
tip() { (cd "$T/w" && "$HERE/Scripts/check-main-tip.sh" "$@"); }
tip "$base" origin || fail "rejected an unmoved main"
git clone -q "$T/o.git" "$T/other" 2> /dev/null
commit "$T/other" "someone else"
git -C "$T/other" push -q origin HEAD:main
tip "$base" origin && fail "missed that main moved"
# The release commit and tag, then the push line from release.yml: both refs must be rejected.
commit "$T/w" "Release"
git -C "$T/w" tag -a v9.9.9 -m t
git -C "$T/w" push --atomic origin HEAD:main refs/tags/v9.9.9 2> /dev/null && fail "atomic push succeeded although main moved"
[ -z "$(git -C "$T/o.git" tag)" ] || fail "tag leaked to the remote"

# release-recovery: the three states, with a stub gh ($T/stub-gh, behaviour chosen by STUB) and the bare remote $T/r.git.
cat > "$T/stub-gh" << 'STUB'
#!/bin/bash
case "$STUB" in
  exists) echo "title: x" ;;
  missing) echo "release not found" >&2; exit 1 ;;
  *) echo "dial tcp: network is unreachable" >&2; exit 1 ;;
esac
STUB
chmod +x "$T/stub-gh"
recover() { (cd "$T/c" && GH="$T/stub-gh" RUN_ID=4242 "$HERE/Scripts/release-recovery.sh" "$@" 2> /dev/null); }
out=$(STUB=missing recover 1.2.3 "$T/r.git") || fail "recovery failed with no tag and no release"
grep -q "safe to re-run" <<< "$out" || fail "state (a) lacks 'safe to re-run'"
git -C "$T/c" tag v1.2.3
git -C "$T/c" push -q "$T/r.git" v1.2.3
out=$(STUB=missing recover 1.2.3 "$T/r.git") || fail "recovery failed for tag without release"
grep -q "gh release create v1.2.3 --verify-tag" <<< "$out" || fail "state (b) lacks gh release create"
grep -q "git show v1.2.3:Package.swift" <<< "$out" || fail "state (b) lacks the manifest checksum check"
grep -q "MISMATCH" <<< "$out" || fail "state (b) check cannot fail"
grep -q "gh run download 4242" <<< "$out" || fail "state (b) lacks the run id"
grep -q -- "--clobber" <<< "$out" && fail "state (b) must not clobber"
out=$(STUB=exists recover 1.2.3 "$T/r.git") || fail "recovery failed for tag with release"
grep -q -- "--clobber" <<< "$out" || fail "state (c) lacks --clobber"
grep -q "gh release download v1.2.3" <<< "$out" || fail "state (c) lacks the re-download check"
grep -q "git show v1.2.3:Package.swift" <<< "$out" || fail "state (c) lacks the manifest checksum check"
STUB=broken recover 1.2.3 "$T/r.git" && fail "a failed release lookup was treated as an answer"
STUB=missing recover 1.2.3 "$T/does-not-exist.git" && fail "an unreachable remote was treated as an answer"
echo "ok"
