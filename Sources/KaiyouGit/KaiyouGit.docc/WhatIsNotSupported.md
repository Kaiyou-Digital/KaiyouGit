# What Is Not Supported

What this release deliberately leaves out, and the limits you should plan around.

## Not supported

- **https and tokens.** An `http://` or `https://` URL throws ``GitError/unsupportedTransport(_:)`` before anything connects, and there is no token credential. Trust of CA certificates for a static OpenSSL on iOS has not been settled. If you have a GitHub https address, rewrite it to the ssh form (`ssh://git@github.com/owner/repo.git`) first.
- **`git://` URLs.** Refused with ``GitError/unsupportedTransport(_:)``, like https.
- **Merge and rebase.** ``Repository/fastForward(to:)`` moves a branch forward when it can and throws ``GitError/notFastForward`` when the branches diverged. Nothing merges.
- **LFS, submodules, hooks, worktrees, stash.**
- **Shallow history management.** There is no depth option and no way to deepen or unshallow a clone.
- **Resuming a clone.** A clone that fails or is cancelled starts again from nothing.
- **Background suspension.** A clone or push does not survive iPadOS suspending the app. Keep the app in the foreground for the length of a transfer.
- **A "trust any host" policy.** See <doc:CredentialsAndHostKeys>.

## Known gaps

Two things the `git` program does are not covered yet. They may come later; the library is additive in 0.x, so adding them will not break existing calls.

- **`clean`**, removing untracked files.
- **The text of the matching ignore rule** (`git check-ignore -v`, which rule ignored a path); ``Repository/isIgnored(_:)`` answers yes or no only. It throws ``GitError/other(class:code:message:)`` for a path with a `.` or `..` component or an absolute path, and never reads those as "not ignored".

## Limits to plan around

These are accepted behaviours, not bugs waiting to be fixed in a patch.

1. **A failed clone can empty an existing empty folder.** If `destination` exists and is empty, and the clone fails or is cancelled, the folder is emptied again. That includes files another process added in the meantime, because it is libgit2's own cleanup and cannot be narrowed. Clone into a fresh subfolder you create, one nothing else writes to. A destination that is not empty is never touched: the call throws ``GitError/destinationNotEmpty(_:)``. A destination the call created itself is removed in full on failure.
2. **Refspecs are not normalised.** Push `HEAD:refs/heads/<branch>`, not `HEAD:<branch>`. The short form fails with a "not a valid reference" error.
3. **Globs and `.` work in some path-taking methods and not in others.** ``Repository/status(paths:)``, ``Repository/stage(paths:)``, ``Repository/unstage(paths:)`` and ``Repository/changedPaths(against:under:)`` accept globs (`notes/*.md`) and `.` for everything. ``Repository/commit(message:author:paths:)`` and ``Repository/checkout(paths:from:)`` take plain file paths and directory names only: a glob or `.` matches nothing there (`commit` throws ``GitError/nothingToCommit`` and leaves the index as it was; `checkout` throws ``GitError/notFound(_:)``). Every method reads `./notes/a.md` and `notes/.` as `notes/a.md` and `notes`, and drops a trailing `/`.
4. **`git://` URLs are refused**, as above.
5. **Key errors depend on libssh2's wording.** A malformed key or a wrong passphrase surfaces as ``GitError/authenticationFailed`` only when libssh2's message contains "private key", "passphrase" or "key data". That wording is tied to libssh2 1.11.1. When libssh2 is upgraded, re-check the mapping in `Errors.swift`; until then an unrecognised message surfaces as ``GitError/network(_:)``.
6. **Network calls run one at a time per repository.** The async methods run on the repository's own serial executor. A long fetch or push on one ``Repository`` makes other calls on that same repository wait. A clone has no repository yet and runs on its own queue.
7. **A stalled connection cannot be cancelled or timed out.** Cancelling the task is noticed only when libgit2 reports progress. A connect to an unreachable host, or a handshake that stalls, reports none, so the call waits until the operating system gives up, and every later call on that ``Repository`` waits behind it (see the previous item). For local calls (`status`, `stage`, `commit`) that must not wait on the network, open a second ``Repository`` on the same folder: that is safe, because `stage`, `unstage` and `commit` read the index from disk before they change it. Timeouts for the server connection need a small C shim, because libgit2's option function is variadic and Swift cannot call it; that is planned for later.
8. **Path mismatches are mostly silent.** A path that is ignored and named explicitly is skipped without an error by ``Repository/stage(paths:)`` and ``Repository/commit(message:author:paths:)``: `commit(paths: ["dir", "config"])` commits only `dir` when `config` is ignored, where `git commit -- dir config` fails. A path that matches nothing is ignored in the same way. Check ``Repository/status(paths:)`` first if that matters. ``Repository/checkout(paths:from:)`` does throw ``GitError/notFound(_:)`` for a path the revision lacks.
9. **`remoteRefs` shares the stalled-connection limit.** ``Repository/remoteRefs(url:auth:)`` has no cancellation or timeout before the first progress tick (it has no progress ticks at all), so a black-holed host holds the call until the operating system gives up. It does not apply `url.<base>.insteadOf` rewrites, because it reads no configuration. A missing local path throws ``GitError/notFound(_:)``; a folder that exists but is not a repository throws ``GitError/other(class:code:message:)`` with libgit2's repository error class, and so does a refused connection, with the operating system's error class and message.
10. **`log` subjects are one line.** ``CommitSummary/subject`` is the first paragraph of the message with its line breaks joined by spaces, as `git log %s` prints it, not only the first line.
11. **No rename detection in `changedPaths(from:to:under:)`.** A renamed file is listed twice, as the old path and the new path.
