# Build and Release

How the C libraries are built, how CI runs, and how a release is cut.

## Overview

KaiyouGit's Swift code links one binary target, `CLibGit2`, an xcframework holding libgit2, libssh2 and OpenSSL as static libraries. Everything here is for people building or releasing the package, not for people using it.

### The xcframework

`Scripts/build-xcframework.sh` clones the three projects at the tags pinned at the top of the script (`OPENSSL_TAG`, `SSH2_TAG`, `LG2_TAG`), each with the commit the tag names (`OPENSSL_SHA`, `SSH2_SHA`, `LG2_SHA`; the peeled commit for an annotated tag). A source folder, fresh or reused, that is not at its pinned commit with a clean tree stops the build, and a reused one that fails the check is fetched again. The release notes list the commits. It builds each for every platform slice, merges the libraries into one per slice and runs `xcodebuild -create-xcframework`. The slices are iOS device (arm64), iOS simulator (arm64) and macOS (arm64 and x86_64 in one library). It needs Xcode, CMake and a network connection, and takes several minutes. Output goes to `OUT_DIR` (default `build/` in the repo) and scratch files to `WORK`.

`Scripts/check-notices.sh` fails if a pinned tag is missing from `THIRD_PARTY_NOTICES.md`, so changing a pin means updating the notices in the same change.

### Building and testing locally

`Package.swift` on `main` holds a placeholder `url:` and `checksum:` for the binary target until a release rewrites them, so it does not resolve on its own. Point it at a local build with `KAIYOUGIT_LOCAL_XCFRAMEWORK`:

```sh
Scripts/build-xcframework.sh
KAIYOUGIT_LOCAL_XCFRAMEWORK=build/CLibGit2.xcframework swift test
```

SwiftPM requires that path to be RELATIVE to the package root. An absolute path fails with "path expected to be relative to package root", so for an xcframework outside the repo write the `../` steps out, for example `../../../../../../private/tmp/kaiyougit-xcf/CLibGit2.xcframework` from a repo six folders below `/`. An empty value is ignored.

### CI

`.github/workflows/ci.yml` runs on every pull request and every push to `main`, on the runner's Xcode. It lints (SwiftFormat, SwiftLint), runs the notices checks, builds the xcframework only when the cache misses, runs `swift test` on macOS and the tests on an iPad simulator. The cache is keyed on the hash of `Scripts/build-xcframework.sh`. That means editing the script rebuilds, but a new runner image or a new Xcode alone does not; if you need a rebuild for that reason, change the script or clear the cache by hand. It never touches the network for tests and holds no secrets.

### Release

A release is one manual action, `.github/workflows/release.yml`, run from `main`, with a version `X.Y.Z` and a `dry_run` flag (default on). It has two jobs:

1. **`build`** (read-only token): checks the version and tag, checks the notices, builds the xcframework, runs the macOS and simulator tests, packages the zip, rewrites `Package.swift` with the asset URL and checksum, verifies the rewrite, and uploads those exact bytes as an artifact named `release-assets`.
2. **`publish`** (`contents: write`, skipped for a dry run): refuses a repository that is not public, checks that `main` has not moved and the zip still matches its checksum, commits the new `Package.swift`, creates an annotated unsigned tag and pushes both in one atomic push, creates the GitHub release with the zip and the notices, and downloads the asset again to verify its checksum.

The release never rebuilds in `publish`: builds are not byte-reproducible, so a recovery reuses the artifact from the failed run.

### Recovery

If `publish` fails, times out or is cancelled, its last step writes a recipe for the state the remote is actually in into the job summary. To get the same text by hand:

```sh
RUN_ID=<the publish run id> Scripts/release-recovery.sh X.Y.Z
```

The recipes check the artifact against the checksum in the tagged `Package.swift` before they do anything. Artifacts expire 30 days after the run.

### The monthly upstream check

`upstream-check.yml` runs on a schedule and opens an issue, with the new tag and its commit, when an upstream library has a newer release than the pin. GitHub disables scheduled workflows after 60 days with no repository activity once a repository is public, so the check can stop without any sign. If it does, re-enable it in the repository's Actions tab, or push any commit.

### Toolchain differences

CI uses whatever Xcode the `macos-latest` runner has, and prints `xcodebuild -version` in the log. The maintainer builds locally with a newer Xcode. The two have already disagreed once: a typed-throws closure in `Repository.initialize` crashed the compiler of Xcode 26.6, so that code returns an `Int32` from the closure and throws outside it. More differences are possible, which is why CI, not the maintainer's machine, is what a release trusts.
