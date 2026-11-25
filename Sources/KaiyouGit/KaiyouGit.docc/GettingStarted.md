# Getting Started

Clone a repository, edit a file, commit, push, and later fetch and fast-forward.

## Overview

Every snippet below uses one ``RemoteAuth`` value. How to build it, and where the fingerprints come from, is in <doc:CredentialsAndHostKeys>.

```swift
import Foundation
import KaiyouGit

let auth = RemoteAuth(
    credentials: .sshKey(user: "git", privateKey: pem, passphrase: nil),
    hostKeys: .pinned(sha256: githubFingerprints)
)
```

### Clone

Clone into a folder that does not exist yet, one you create for the purpose, rather than into a folder other processes write to.

```swift
let folder = documents.appendingPathComponent("notes")
let repo = try await Repository.clone(
    from: "ssh://git@github.com/owner/notes.git",
    to: folder,
    auth: auth,
    progress: { transfer in
        print("\(transfer.receivedObjects) of \(transfer.totalObjects) objects")
    }
)
```

`progress` is optional. Cancelling the task that called `clone` stops the transfer at the next progress tick and throws ``GitError/cancelled``. See <doc:WhatIsNotSupported> for what a failed clone leaves behind.

To open a repository that is already on disk, use ``Repository/open(at:)``.

### Edit, stage and commit

Edit files with the usual Foundation calls, then stage and commit.

```swift
try "Hello\n".write(
    to: folder.appendingPathComponent("hello.md"), atomically: true, encoding: .utf8
)
let changes = try await repo.status()          // [StatusEntry]: hello.md is untracked
try await repo.stage(paths: ["hello.md"])
let id = try await repo.commit(
    message: "Add hello",
    author: Author(name: "Ada", email: "ada@example.com")
)
print(id.hex)
```

``Repository/stageAll()`` stages everything, deletions included. Pass `paths:` to ``Repository/commit(message:author:paths:)`` to commit only those files or folders and leave the rest of the index alone.

### Push

```swift
try await repo.push(refspec: "HEAD:refs/heads/main", auth: auth)
```

Use the full ref name. The library does not expand `HEAD:main`. A push the remote refuses because someone else pushed first throws ``GitError/notFastForward``.

### Fetch and fast-forward

```swift
try await repo.fetch(auth: auth)
let counts = try await repo.aheadBehind(local: "HEAD", upstream: "refs/remotes/origin/main")
if counts.behind > 0 {
    try await repo.fastForward(to: "refs/remotes/origin/main")
}
```

``Repository/fastForward(to:)`` never merges. If the branches have diverged it throws ``GitError/notFastForward``; if uncommitted changes to a file would be overwritten it throws ``GitError/wouldOverwriteLocalChanges`` and changes nothing.

### See what others published

After a fetch, list the commits and the files that differ between your branch and its upstream.

```swift
try await repo.fetch(auth: auth)
let incoming = try await repo.log(from: "HEAD", to: "@{u}", limit: 10)
for commit in incoming {
    print(commit.id.hex.prefix(7), commit.subject, commit.authorName)
}
let files = try await repo.changedPaths(from: "HEAD", to: "@{u}", under: ["notes"])
```

``Repository/log(from:to:limit:)`` is `git log base..tip`: the commits reachable from `tip` and not from `base`, newest first, as ``CommitSummary`` values. Leave `limit` out for all of them. ``Repository/changedPaths(from:to:under:)`` is `git diff --name-only --no-renames`: the sorted paths that differ between two commits' trees, a rename counting as two paths. Both accept the revisions ``Repository/resolve(_:)`` does (`HEAD`, a branch, `origin/main`, `HEAD~1`, `@{u}`) and throw ``GitError/notFound(_:)`` for one that does not exist. A malformed revision (`HEAD^{nope}`, an empty string, `a..b`) throws ``GitError/other(class:code:message:)`` (class 3, code -12) from both, while ``Repository/resolve(_:)`` returns nil for it. A commit's author or committer name that is not valid UTF-8 is repaired with U+FFFD, and a commit with a non-UTF-8 `encoding` header is not re-encoded the way git does.

### Check whether a remote is empty

``Repository/remoteRefs(url:auth:)`` is `git ls-remote`. It needs no repository, so use it before the first clone or push. The refs come back in the order `git ls-remote` prints them, not sorted. An empty remote returns `[]` and is not an error; a missing local path throws ``GitError/notFound(_:)``.

```swift
let refs = try await Repository.remoteRefs(
    url: "ssh://git@github.com/owner/new-notes.git", auth: auth
)
if refs.isEmpty {
    // Nothing on the remote yet: safe to push a first branch.
}
```

It has the limits listed in <doc:WhatIsNotSupported>, including that a stalled connection cannot be cancelled.

### Handling errors

Every method throws ``GitError``. The ones worth handling separately are ``GitError/authenticationFailed``, ``GitError/hostKeyRejected``, ``GitError/notFastForward`` and ``GitError/wouldOverwriteLocalChanges``. Two more concern ``Repository/commit(message:author:paths:)``: ``GitError/nothingToCommit`` (the index or the given paths already match HEAD) and ``GitError/commitCreatedButIndexNotSaved(commit:reason:)``, where the commit exists but the index file could not be saved. Do not retry the commit in that case. Only a path-scoped commit leaves the on-disk index stale: other ``Repository`` instances (and the git CLI) see those paths reversed as staged changes until the cause is gone (for example a stale `index.lock` is removed) and ``Repository/stageAll()`` (or ``Repository/stage(paths:)`` for the same paths) is called. ``GitError/detachedHead`` means an operation that needs a branch found HEAD detached.

```swift
do {
    try await repo.fetch(auth: auth)
} catch GitError.hostKeyRejected {
    // The server's key is not in the set you pinned.
} catch GitError.authenticationFailed {
    // The server refused the key, or the key text could not be used.
}
```
