# KaiyouGit: design

Status: implemented for 0.1.0. The first release is not cut yet.

## Intent

Some apps need git where the `git` program cannot run. iPadOS cannot spawn processes, so anything that shells out to `git` and `ssh` has no iPad version. libgit2 built with libssh2 and OpenSSL does the same work in process, on iPadOS first and on macOS too.

KaiyouGit wraps that C stack in a small Swift 6 API. It is built for apps that need git on iPadOS, and for anyone who needs in-process git over ssh.

## Goals

- In-process git for iOS 17 and macOS 14 (arm64 and x86_64 on macOS): no `Process`, no bundled `git` binary.
- Cover what an app that syncs content with a git repository does: clone, fetch, push, status, stage, commit, fast-forward, reset, checkout, reading files and history, and nothing speculative beyond that.
- Safe by default: credentials and the ssh host-key policy travel together as one required argument, with no global state, so a caller cannot forget to verify the host.
- Maintainable by one person: semver, DocC documentation, CI that builds and tests everything, and a release that is one manual action.
- No app-specific types in the public API.

## Non-goals

- Replacing the `git` CLI (merge, rebase, stash, submodules, LFS, hooks, worktrees).
- Being a complete libgit2 binding. Issues and pull requests are welcome, but the API is shaped by the apps it serves.
- Windows, Linux, watchOS, tvOS, visionOS.

## Anti-goals

These are failures even if everything works:

- A release that ships a binary nobody can trace to a public build log and pinned source versions.
- A host-key check that can be skipped by omission.
- An OpenSSL or libgit2 that falls behind security releases because rebuilding is painful.

## Constraints

- MIT licence for the library. libgit2 (GPLv2 with linking exception), libssh2 (BSD) and OpenSSL (Apache-2.0) travel with it: `THIRD_PARTY_NOTICES.md` is in the repository and in each release asset, and is re-checked whenever a source tag is bumped.
- Swift 6 language mode, tools-version 6.0, warning-free. iOS 17 and macOS 14 floors.
- Consumers pin by exact tag, so a release must make that safe.

## Approaches considered

How the C code ships:

1. A prebuilt xcframework in a separate dependencies release. Rejected: two kinds of release to keep track of.
2. **One release carrying both the Swift code and the exact xcframework it needs (chosen).** One tag, one set of source versions, one binary. The cost is that every dependency rebuild (an OpenSSL security fix, say) forces a new library version, usually a patch.
3. Build the C code from source inside SwiftPM. Rejected: OpenSSL's assembly and build flags do not fit SwiftPM, so the package would carry a fork of the sources.

Why not an existing package, as checked when the design was written (November 2026):

- SwiftGitX wraps libgit2 1.9.2 but exposes no credential callbacks or shallow options, and its libgit2 packaging builds the ssh transport as `GIT_SSH_EXEC`, which runs the system `ssh` and cannot work on iOS.
- `libgit2-apple` has in-process ssh but had not been updated since May 2024 and expects you to build its dependencies by hand.

## The API and its accepted limits

`Repository` is an actor that owns one libgit2 handle, so calls on a repository are serialised. Local operations are plain actor methods; network operations (`clone`, `fetch`, `push`, `remoteRefs`) are `async`, and so is `fastForward`, which is local. `RemoteAuth` bundles `Credentials` (`.sshKey`, an in-memory PEM, never a path) with a `HostKeyPolicy` (pinned SHA-256 fingerprints, or a closure; there is no "trust everything" case). `GitError` is a typed enum with a case per failure a caller must tell apart, and `.other` carries libgit2's class, code and message.

Operations: `clone`, `fetch`, `push`, `fastForward` (never merges), `status`, `stage`, `stageAll`, `unstage`, `commit` (optionally scoped to paths), `resetHard`, `checkout(paths:)`, `contents(of:at:)`, `listTree`, `changedPaths(against:)`, `changedPaths(from:to:)`, `log(from:to:limit:)`, `remoteRefs(url:auth:)`, `isIgnored`, `config`, `remoteURL` and friends. Known gaps, which may come later as additive changes: `clean` and the text of the rule behind `isIgnored`.

The limits a caller must accept, each documented in the DocC article "What Is Not Supported":

1. **ssh only.** `https://`, `http://` and `git://` throw `.unsupportedTransport`. How OpenSSL would find trusted CA certificates on iOS is unsettled, so https waits for a later release.
2. **A failed clone can empty an existing empty folder** (libgit2's own cleanup, which cannot be narrowed). A destination the call created is removed in full; a non-empty destination is never touched. There is no resume, and a transfer does not survive iPadOS suspending the app.
3. **Refspecs are not normalised.** Push `HEAD:refs/heads/<branch>`, not `HEAD:<branch>`.
4. **Pathspecs differ by method.** `status`, `stage`, `unstage` and `changedPaths` accept globs and `.`; `commit(paths:)` and `checkout(paths:)` take plain paths and directory names only. Paths that match nothing are skipped silently in `stage` and `commit`.
5. **A stalled connection cannot be cancelled or timed out.** Cancellation is noticed only when libgit2 reports progress, so a connect to an unreachable host, and any `remoteRefs` call, waits until the operating system gives up. Timeouts need a small C shim, because libgit2's option function is variadic.
6. **Sign-in errors depend on libssh2's wording.** A malformed key or wrong passphrase surfaces as `.authenticationFailed` only when libssh2's message matches; the mapping is tied to libssh2 1.11.1 and is re-checked on upgrade.

Other decisions:

- The library ships no host-key fingerprints, because they rotate. Callers pass the set they trust, in the unpadded base64 form GitHub publishes.
- A path-scoped commit means `git commit -- paths`: exactly those paths are committed and the rest of the index is left alone.
- There is no end-of-line conversion and no `.gitattributes` handling.
- Once a release exists, `Package.swift` on `main` points at the latest release's xcframework URL and checksum. `KAIYOUGIT_LOCAL_XCFRAMEWORK` overrides it with a local path, relative to the package root, so a change can be tested against a freshly built binary.

## Evidence

Tested with libgit2 1.9.7, libssh2 1.11.1 and OpenSSL 3.5.9, built static, ssh through libssh2:

- **Physical iPad**, 25 November 2026 (a physical iPad, iPadOS 27.0.1): the offline suite (111 tests, 6 live ssh tests skipped). On 24 November 2026 the whole suite ran there with the live ssh tests on, including clone, commit, push and fetch back over ssh against a scratch repository on GitHub, a wrong key, a malformed key and a wrong host fingerprint.
- **iPad simulator and macOS**, 25 November 2026: the offline suite, with macOS parity tests that compare results with the `git` CLI. Exact counts are in the README status table.

Not verified: https, behaviour when iPadOS suspends the app during a long clone, and large pushes.

## Release and recovery

`release.yml` is run by hand with a version. A read-only `build` job builds the xcframework on macOS runners, then a `publish` job uploads it to a GitHub release, commits the new URL and checksum into `Package.swift` and tags that commit, atomically, with guards on the tag and on the tip of `main`. The build aborts if a source is not at its pinned commit, and the release notes list the commits. `Scripts/release-recovery.sh` prints the recovery recipe for whatever state the remote is left in. A monthly scheduled job checks upstream for security releases and opens an issue; it never releases. Detail: the DocC article "Build and Release".
