# KaiyouGit

In-process git for Swift apps on iOS and macOS, over ssh.

iPadOS apps cannot spawn the `git` program, so anything that shells out to it cannot run there. KaiyouGit wraps libgit2, libssh2 and OpenSSL (built into one static xcframework) in a small Swift 6 API, so clone, commit, push, fetch and fast-forward happen inside your app. It is built first for iPadOS and also runs on macOS. It is ssh only: an `https://` URL throws `GitError.unsupportedTransport`.

## Platforms and bundled versions

- iOS 17 (device arm64, simulator arm64) and macOS 14 (arm64 and x86_64). Swift 6 language mode, tools-version 6.0.
- libgit2 `v1.9.7`, libssh2 `libssh2-1.11.1`, OpenSSL `openssl-3.5.9`, static. These are the pins in `Scripts/build-xcframework.sh`.

## Installation

Add the package with an exact version:

```swift
.package(url: "https://github.com/Kaiyou-Digital/KaiyouGit.git", exact: "0.1.0")
```

Until the first release exists, the package does not resolve on its own. `Package.swift` holds a placeholder `url:` and `checksum:` for the binary target, which a release rewrites. To work on it before then, build the xcframework (`Scripts/build-xcframework.sh`) and set `KAIYOUGIT_LOCAL_XCFRAMEWORK` to its path, which SwiftPM requires to be relative to the package root:

```sh
KAIYOUGIT_LOCAL_XCFRAMEWORK=build/CLibGit2.xcframework swift test
```

## Usage

```swift
import Foundation
import KaiyouGit

let auth = RemoteAuth(
    credentials: .sshKey(user: "git", privateKey: privateKeyPEM, passphrase: nil),
    hostKeys: .pinned(sha256: githubFingerprints) // read from https://api.github.com/meta
)

// Clone into a folder that does not exist yet.
let folder = documents.appendingPathComponent("notes")
let repo = try await Repository.clone(
    from: "ssh://git@github.com/owner/notes.git", to: folder, auth: auth
)

try "Hello\n".write(to: folder.appendingPathComponent("hello.md"), atomically: true, encoding: .utf8)
try await repo.stageAll()
try await repo.commit(message: "Add hello", author: Author(name: "Ada", email: "ada@example.com"))
try await repo.push(refspec: "HEAD:refs/heads/main", auth: auth)
```

To see what others published before you fast-forward, and to check that a remote is empty before the first push:

```swift
try await repo.fetch(auth: auth)
let incoming = try await repo.log(from: "HEAD", to: "@{u}", limit: 10)      // [CommitSummary], newest first
let files = try await repo.changedPaths(from: "HEAD", to: "@{u}")           // [String], sorted
let refs = try await Repository.remoteRefs(url: "ssh://git@github.com/owner/new.git", auth: auth) // [RemoteRef]
let remoteIsEmpty = refs.isEmpty
```

The library ships no host-key fingerprints and has no "trust any host" option. The DocC articles (Getting Started, Credentials and Host Keys) show how to get the fingerprints and why. Build the documentation in Xcode with Product > Build Documentation.

## Status

Real results, built against a locally built xcframework. The live ssh tests need a scratch remote and a key, so they only ran where noted. All rows are from 25 November 2026.

| Where | Toolchain and OS | What ran | Result |
| --- | --- | --- | --- |
| macOS (arm64), 25 Nov 2026 | Xcode 27.2, macOS 27.0.1, `swift test` | the suite without live ssh | 121 tests executed, 6 of them skipped (the live ssh tests), 0 failures |
| iOS simulator, 25 Nov 2026 | Xcode 27.2, iPad Air 11-inch (M4) simulator, `xcodebuild test` | the suite without live ssh | 111 tests executed, 6 of them skipped (the live ssh tests), 0 failures |
| Physical iPad, 25 Nov 2026 | a physical iPad, iPadOS 27.0.1, Xcode 27.2, `xcodebuild test` through a throwaway host app | the suite without live ssh | 111 tests executed, 6 of them skipped (the live ssh tests), 0 failures |

The simulator run has 8 fewer tests because 8 tests are macOS only (7 compare against the `git` CLI, 1 uses `ssh-keygen`). The 6 live ssh tests need a scratch remote and a key. They last ran on a physical iPad on 24 November 2026 (67 tests at that point, 0 failures), before the 2 that list a remote's refs (`remoteRefs`) existed, so those 2 have not run on a device.

The 4 live ssh tests passed on the physical iPad, against a scratch repository on GitHub using throwaway `kaiyougit-test-*` branches: clone, commit, push and fetch back over ssh (`testSSHCloneCommitPush`), a wrong private key (`.authenticationFailed`), a malformed key, and a wrong host fingerprint (`.hostKeyRejected`). Fast-forward is covered by the offline suite against local remotes, not by the live ssh tests. https is not supported, so it has no status.

## Not supported

- https and tokens (an `https://` or `http://` URL throws `.unsupportedTransport`, and so does `git://`).
- Merge and rebase (`fastForward` only; diverged branches throw `.notFastForward`).
- LFS and submodules.
- Shallow history management (no depth option, no deepening).
- Resuming a clone.
- A clone or push surviving the app being suspended in the background.
- Cancelling or timing out a stalled connection. Cancellation is noticed only when libgit2 reports progress, so a connect to an unreachable host blocks every later call on that `Repository` until the system gives up. Use a second `Repository` on the same folder for local calls.
- `remoteRefs` has the same stalled-connection limit (no cancellation or timeout before the first progress tick), does not apply `url.<base>.insteadOf` rewrites, and throws `.notFound` for a missing local path, `.other` for a folder that is not a repository (libgit2's repository error class) and `.other` with the operating system's error class for a refused connection.
- `changedPaths(from:to:under:)` has no rename detection: a rename is two paths. `log`'s `subject` is the first paragraph of the message with line breaks joined by spaces, as `git log %s` prints it.
- Globs and `.` in `commit(paths:)` and `checkout(paths:)` (`status`, `stage`, `unstage` and `changedPaths` accept them). An ignored path named explicitly, or a path that matches nothing, is skipped without an error in `stage` and `commit`.

The DocC article "What Is Not Supported" also lists the accepted limits, such as a failed clone emptying an existing empty destination folder (clone into a fresh subfolder you create) and pushing `HEAD:refs/heads/<branch>` rather than `HEAD:<branch>`.

### Known gaps

Two things the `git` program does are not covered yet: `clean` (removing untracked files) and the text of the rule behind `isIgnored` (what `git check-ignore -v` prints, that is, which rule ignored a path). They may come later. The library is additive in 0.x, so adding them will not break existing calls.

## Toolchain

CI runs whatever Xcode the `macos-latest` runner has (Xcode 26.6, Swift 6.3.3 in the latest green run), while the maintainer builds locally with Xcode 27.2. The two have already disagreed once: a typed-throws closure crashed the Xcode 26.6 compiler, so `Repository.initialize` returns the libgit2 code from its closure and throws outside it. A green CI run is the check, not a local build.

## Licences

KaiyouGit is MIT licensed (`LICENSE`). The xcframework is built from libgit2 (GPLv2 with a linking exception), libssh2 (BSD) and OpenSSL (Apache-2.0). The full texts, with the source tags, are in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md), which also ships with each release.

## Contributing and issues

Issues and pull requests are welcome. The API is shaped by the apps the library was built for, so open an issue before a large change. CI must be green: lint, the notices check, and the macOS and simulator tests.

## Releasing

A release is a manual run of `.github/workflows/release.yml` from `main`: a `build` job, then a `publish` job (a dry run publishes nothing). If `publish` fails part way, `Scripts/release-recovery.sh X.Y.Z` prints the recovery recipe for the state the remote is in. The DocC article "Build and Release" has the detail.

Each upstream source is pinned by tag and by commit (`*_SHA` in `Scripts/build-xcframework.sh`); the build aborts if a source is not at that commit, and the release notes list the commits. The monthly upstream check (`upstream-check.yml`) is a scheduled workflow, and GitHub disables scheduled workflows after 60 days with no repository activity once a repository is public. If it stops running, re-enable it in the Actions tab (or push any commit).
