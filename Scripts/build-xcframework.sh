#!/bin/bash
# Builds CLibGit2.xcframework (libgit2 + libssh2 + OpenSSL, static) with three slices:
# ios-arm64, ios-arm64-simulator, macos-arm64_x86_64.
# Usage: Scripts/build-xcframework.sh   (env: WORK scratch dir, OUT_DIR output dir)
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-${TMPDIR:-/tmp}/kaiyougit-build}"
OUT_DIR="${OUT_DIR:-$HERE/build}"
# Source pins. Scripts/check-notices.sh and the CI cache key read these six lines. Each *_SHA is the commit the tag
# names (the peeled one for an annotated tag: `git ls-remote --tags <url> '<tag>^{}'`), so a moved or re-created
# upstream tag fails the build instead of changing what ships.
OPENSSL_TAG=openssl-3.5.9
OPENSSL_SHA=45e844fa2a14ec92d146bd8f5778ac130b6625fb
SSH2_TAG=libssh2-1.11.1
SSH2_SHA=a312b43325e3383c865a87bb1d26cb52e3292641
LG2_TAG=v1.9.7
LG2_SHA=49e408b3208bc3093757a1c2db938d3590f3f412
MIN_IOS=17.0
MIN_MAC=14.0
JOBS=$(sysctl -n hw.ncpu)
mkdir -p "$WORK" "$OUT_DIR"

set -E # make the ERR trap fire inside functions too
trap 'echo "build-xcframework.sh failed at line $LINENO: $BASH_COMMAND (logs: $WORK/b-*/*.log)" >&2' ERR

# Clones into a temporary name and renames on success, so a partial clone is never reused. Every source, new or reused,
# must be at the pinned commit with a clean tree; a mismatch aborts rather than building something else.
verify() { # dir tag sha
  local d="$WORK/src-$1" head
  head=$(git -C "$d" rev-parse HEAD 2> /dev/null) || return 1
  [ "$head" = "$3" ] && [ -z "$(git -C "$d" status --porcelain)" ]
}
fetch() { # dir tag sha url
  local d="$WORK/src-$1"
  if [ -d "$d" ] && verify "$1" "$2" "$3"; then return; fi
  rm -rf "$d" "$d.tmp"
  git clone -q -c advice.detachedHead=false --depth 1 --branch "$2" "$4" "$d.tmp"
  mv "$d.tmp" "$d"
  verify "$1" "$2" "$3" || {
    echo "$d is at $(git -C "$d" rev-parse HEAD), not the pinned $3 for $2 (or the tree is dirty); aborting" >&2
    exit 1
  }
}
fetch openssl "$OPENSSL_TAG" "$OPENSSL_SHA" https://github.com/openssl/openssl.git
fetch ssh2 "$SSH2_TAG" "$SSH2_SHA" https://github.com/libssh2/libssh2.git
fetch lg2 "$LG2_TAG" "$LG2_SHA" https://github.com/libgit2/libgit2.git
cat > "$OUT_DIR/source-pins.txt" << PINS
libgit2 $LG2_TAG $LG2_SHA
libssh2 $SSH2_TAG $SSH2_SHA
OpenSSL $OPENSSL_TAG $OPENSSL_SHA
PINS
[ -z "${FETCH_ONLY:-}" ] || exit 0 # lets Scripts/test-release-scripts.sh check the pins without building

# Builds OpenSSL, libssh2 and libgit2 for one arch and merges them into $WORK/lib-$name.a.
# args: name sdk openssl-target arch min-version openssl-min-flag [cmake system name]
build_one() {
  local name=$1 sdk=$2 target=$3 arch=$4 min=$5 minflag=$6 sysname=${7:-}
  local out="$WORK/out-$name" b="$WORK/b-$name"
  rm -rf "$out" "$b"
  mkdir -p "$b"

  # OpenSSL builds in-tree, so give each build its own copy.
  cp -R "$WORK/src-openssl" "$b/openssl"
  (
    cd "$b/openssl"
    ./Configure "$target" "-arch $arch" "$minflag" \
      no-shared no-tests no-apps no-docs no-dso --prefix="$out" > ../openssl-configure.log 2>&1
    make -j"$JOBS" build_libs > ../openssl-make.log 2>&1
    make install_dev > /dev/null 2>&1
  )

  local common=("-DCMAKE_OSX_SYSROOT=$sdk" "-DCMAKE_OSX_ARCHITECTURES=$arch"
    "-DCMAKE_OSX_DEPLOYMENT_TARGET=$min" "-DCMAKE_FIND_ROOT_PATH=$out" "-DCMAKE_INSTALL_PREFIX=$out"
    -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DBUILD_EXAMPLES=OFF
    "-DOPENSSL_INCLUDE_DIR=$out/include" "-DOPENSSL_CRYPTO_LIBRARY=$out/lib/libcrypto.a" "-DOPENSSL_SSL_LIBRARY=$out/lib/libssl.a")
  [ -n "$sysname" ] && common+=("-DCMAKE_SYSTEM_NAME=$sysname")

  cmake -S "$WORK/src-ssh2" -B "$b/ssh2" "${common[@]}" -DCRYPTO_BACKEND=OpenSSL -DENABLE_ZLIB_COMPRESSION=OFF > "$b/ssh2-cfg.log" 2>&1
  cmake --build "$b/ssh2" -j"$JOBS" > "$b/ssh2-make.log" 2>&1
  cmake --install "$b/ssh2" > /dev/null 2>&1

  PKG_CONFIG_PATH="$out/lib/pkgconfig" cmake -S "$WORK/src-lg2" -B "$b/lg2" "${common[@]}" \
    -DBUILD_TESTS=OFF -DBUILD_CLI=OFF -DUSE_SSH=libssh2 -DUSE_HTTPS=OpenSSL -DUSE_BUNDLED_ZLIB=ON -DUSE_NTLMCLIENT=OFF \
    -DREGEX_BACKEND=builtin > "$b/lg2-cfg.log" 2>&1
  cmake --build "$b/lg2" -j"$JOBS" > "$b/lg2-make.log" 2>&1
  cmake --install "$b/lg2" > /dev/null 2>&1

  libtool -static -o "$WORK/lib-$name.a" "$out/lib/libgit2.a" "$out/lib/libssh2.a" "$out/lib/libssl.a" "$out/lib/libcrypto.a" 2> /dev/null
  echo "built $name"
}

build_one ios-sim iphonesimulator iossimulator-xcrun arm64 "$MIN_IOS" "-mios-simulator-version-min=$MIN_IOS" iOS
build_one ios-device iphoneos ios64-xcrun arm64 "$MIN_IOS" "-miphoneos-version-min=$MIN_IOS" iOS
build_one mac-arm64 macosx darwin64-arm64-cc arm64 "$MIN_MAC" "-mmacosx-version-min=$MIN_MAC"
build_one mac-x86_64 macosx darwin64-x86_64-cc x86_64 "$MIN_MAC" "-mmacosx-version-min=$MIN_MAC"
lipo -create "$WORK/lib-mac-arm64.a" "$WORK/lib-mac-x86_64.a" -output "$WORK/lib-mac.a"

rm -rf "$WORK/headers" && mkdir "$WORK/headers"
cp "$WORK/out-ios-device/include/git2.h" "$WORK/headers/"
cp -R "$WORK/out-ios-device/include/git2" "$WORK/headers/git2"
cat > "$WORK/headers/module.modulemap" << 'MAP'
module CLibGit2 {
    header "git2.h"
    link "z"
    link "iconv"
    export *
}
MAP

rm -rf "$OUT_DIR/CLibGit2.xcframework"
xcodebuild -create-xcframework \
  -library "$WORK/lib-ios-device.a" -headers "$WORK/headers" \
  -library "$WORK/lib-ios-sim.a" -headers "$WORK/headers" \
  -library "$WORK/lib-mac.a" -headers "$WORK/headers" \
  -output "$OUT_DIR/CLibGit2.xcframework"
