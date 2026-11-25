import CLibGit2
import Foundation

/// How far a clone or fetch has got.
public struct TransferProgress: Sendable {
    /// Objects received so far.
    public let receivedObjects: Int
    /// Objects the server says it will send.
    public let totalObjects: Int
    /// Bytes received so far.
    public let receivedBytes: Int
}

/// Network calls. Each runs to the end without suspending, on the repository's own queue (a clone on a queue of its
/// own), so a second call on the same repository waits for the first. `progress` is called synchronously on the
/// calling task and must not block; cancelling that task stops the transfer at the next progress tick and throws
/// `.cancelled`. `ssh://` and scp-style (`git@host:path`) URLs need `auth`; `file://` and local paths need none; any
/// other scheme (https and http included) throws `.unsupportedTransport` before anything connects.
public extension Repository {
    /// `git clone url destination`. `destination` must be missing or an empty directory; a non-empty one throws
    /// `.destinationNotEmpty` and is never touched. On failure or cancellation:
    /// - a destination this call created (with any missing parents) is removed in full;
    /// - an existing empty destination is emptied, including anything another process put in it meanwhile. That is
    ///   libgit2's own cleanup, which cannot be narrowed, so on a folder others write to (iCloud, say) clone into a
    ///   fresh subfolder that nothing else writes to, and only the clone's files are removed.
    ///
    /// A `..` in `destination` is resolved by name (`URL.standardized`), not by following a symlink before it.
    static func clone(
        from url: String,
        to destination: URL,
        auth: RemoteAuth? = nil,
        progress: (@Sendable (TransferProgress) -> Void)? = nil
    ) async throws -> Repository {
        try await CloneRunner().clone(from: url, to: destination, auth: auth, progress: progress)
    }

    /// `git fetch --tags --force remote`: remote-tracking branches and tags follow the remote, rewritten or not.
    func fetch(
        remote: String = "origin",
        auth: RemoteAuth? = nil,
        progress: (@Sendable (TransferProgress) -> Void)? = nil
    ) async throws {
        let gitRemote = try connectableRemote(remote, auth: auth)
        defer { git_remote_free(gitRemote) }
        var opts = git_fetch_options()
        try check(git_fetch_options_init(&opts, UInt32(GIT_FETCH_OPTIONS_VERSION)))
        opts.download_tags = GIT_REMOTE_DOWNLOAD_TAGS_ALL
        try RemoteContext(auth: auth, progress: progress).run { callbacks in
            opts.callbacks = callbacks
            return git_remote_fetch(gitRemote, nil, &opts, nil)
        }
    }

    /// `git push remote refspec` (for example `HEAD:refs/heads/main`); a rejected update throws, a non-fast-forward
    /// one as `.notFastForward`.
    func push(remote: String = "origin", refspec: String, auth: RemoteAuth? = nil) async throws {
        let gitRemote = try connectableRemote(remote, auth: auth, forPush: true)
        defer { git_remote_free(gitRemote) }
        var opts = git_push_options()
        try check(git_push_options_init(&opts, UInt32(GIT_PUSH_OPTIONS_VERSION)))
        let specs = CStrings([refspec])
        defer { specs.free() }
        var array = specs.array
        try RemoteContext(auth: auth, progress: nil).run { callbacks in
            opts.callbacks = callbacks
            return git_remote_push(gitRemote, &array, &opts)
        }
    }

    /// `git merge --ff-only rev`: nothing when the branch is at or ahead of `rev`, `.notFastForward` when they
    /// diverged. The working tree is updated first with a safe checkout (`.wouldOverwriteLocalChanges`, changing
    /// nothing, if that would overwrite uncommitted changes) and the branch moves only after that succeeds; if it then
    /// cannot move (a stale lock, say), the checkout is undone and that error thrown; if the undo fails too, the error
    /// says the working tree and index were left at `rev` and carries both messages.
    func fastForward(to rev: String) async throws {
        guard let branch = currentBranch else { throw GitError.detachedHead }
        let branchRef = "refs/heads/" + branch
        var tip = git_oid() // stays zero on an unborn branch, which `create_matching` below reads as "must not exist"
        let found = git_reference_name_to_id(&tip, handle, branchRef)
        if found != GIT_ENOTFOUND.rawValue { try check(found) }
        var target: OpaquePointer?
        try check(git_annotated_commit_from_revspec(&target, handle, rev))
        defer { git_annotated_commit_free(target) }
        var analysis = GIT_MERGE_ANALYSIS_NONE
        var preference = GIT_MERGE_PREFERENCE_NONE
        var heads: [OpaquePointer?] = [target]
        try check(git_merge_analysis(&analysis, &preference, handle, &heads, 1))
        if analysis.rawValue & GIT_MERGE_ANALYSIS_UP_TO_DATE.rawValue != 0 { return }
        guard analysis.rawValue & GIT_MERGE_ANALYSIS_FASTFORWARD.rawValue != 0 else { throw GitError.notFastForward }

        let targetOid = git_annotated_commit_id(target)
        var commit: OpaquePointer?
        try check(git_commit_lookup(&commit, handle, targetOid))
        defer { git_commit_free(commit) }
        var tree: OpaquePointer?
        try check(git_commit_tree(&tree, commit))
        defer { git_tree_free(tree) }
        var opts = git_checkout_options()
        try check(git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
        opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue // never FORCE: a conflict fails before writing anything
        try check(git_checkout_tree(handle, tree, &opts))

        // Moves the branch only from the tip read above (or creates it, when unborn), never over a concurrent move.
        var moved: OpaquePointer?
        defer { git_reference_free(moved) }
        do {
            try check(git_reference_create_matching(
                &moved, handle, branchRef, targetOid, 1, &tip, "fast-forward to \(rev)"
            ))
        } catch {
            // The branch did not move: put back what the checkout changed (HEAD's tree, the old tip, against the
            // target as baseline, so files edited since are kept). shortcut: an unborn branch has no tree to go back
            // to and keeps the files; check out the empty tree there if that matters.
            opts.baseline = tree
            let rollback = git_checkout_tree(handle, nil, &opts)
            guard rollback < 0 else { throw error }
            let last = git_error_last()
            let detail = last.map { String(cString: $0.pointee.message) } ?? "no message"
            throw GitError.other(
                class: last?.pointee.klass ?? 0,
                code: rollback,
                message: "the branch could not move (\(error)) and undoing the checkout also failed (\(detail)); "
                    + "the working tree and index were left at \(rev)"
            )
        }
    }

    /// The remote called `name`, once its URL (the push URL, if set, `forPush`) passes `requireSupportedTransport`.
    /// The caller frees it.
    private func connectableRemote(
        _ name: String, auth: RemoteAuth?, forPush: Bool = false
    ) throws(GitError) -> OpaquePointer {
        var remote: OpaquePointer?
        try check(git_remote_lookup(&remote, handle, name))
        let url = (forPush ? git_remote_pushurl(remote) : nil) ?? git_remote_url(remote)
        do {
            try requireSupportedTransport(url.map { String(cString: $0) } ?? "", auth: auth)
        } catch {
            git_remote_free(remote)
            throw error
        }
        return remote!
    }
}

/// Throws, before anything connects, for a URL this library will not use: a scheme other than ssh and `file`
/// (https and http are not in 1.0), or ssh without `auth`. Like git, `host:path` with no slash before the colon is
/// scp-style ssh, and anything else without a scheme is a local path.
func requireSupportedTransport(_ url: String, auth: RemoteAuth?) throws(GitError) {
    let isSSH: Bool
    if let separator = url.range(of: "://") {
        let scheme = url[..<separator.lowerBound].lowercased()
        guard ["ssh", "ssh+git", "git+ssh", "file"].contains(scheme) else { throw .unsupportedTransport(scheme) }
        isSSH = scheme != "file"
    } else if let colon = url.firstIndex(of: ":") {
        isSSH = url.firstIndex(of: "/").map { colon < $0 } ?? true
    } else {
        isSSH = false
    }
    if isSSH, auth == nil { throw .authenticationFailed }
}

/// The filesystem path of a local `url` (a plain path or `file://`, classified as `requireSupportedTransport` does),
/// or nil for an ssh one.
func localPath(of url: String) -> String? {
    if let separator = url.range(of: "://") {
        guard url[..<separator.lowerBound].lowercased() == "file" else { return nil }
        return URL(string: url)?.path ?? String(url[separator.upperBound...])
    }
    guard let colon = url.firstIndex(of: ":") else { return url }
    return url.firstIndex(of: "/").map { $0 < colon } ?? false ? url : nil
}

/// Runs a clone on a dispatch queue of its own rather than a thread of Swift's cooperative pool (a clone can block
/// for minutes), still inside the calling task, so the progress callback sees that task's cancellation.
private actor CloneRunner {
    private let queue = DispatchSerialQueue(label: "digital.kaiyou.KaiyouGit.clone")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    func clone(
        from url: String,
        to destination: URL,
        auth: RemoteAuth?,
        progress: (@Sendable (TransferProgress) -> Void)?
    ) throws(GitError) -> Repository {
        try LibGit2.ensureInitialized()
        try requireSupportedTransport(url, auth: auth)
        // One spelling for the checks, the walk, git_clone and the cleanup, so `..` after a symlink cannot make them
        // name different directories. Not `standardizedFileURL`, which also turns an existing /private/var/... into
        // /var/...: without `.` or `..` this is `destination` itself.
        let local = destination.standardized
        var opts = git_clone_options()
        try check(git_clone_options_init(&opts, UInt32(GIT_CLONE_OPTIONS_VERSION)))
        let created = try Self.prepare(local, for: destination) // last before the clone, so nothing above leaks it
        var repo: OpaquePointer?
        var refused = false
        do {
            try RemoteContext(auth: auth, progress: progress).run { callbacks in
                opts.fetch_opts.callbacks = callbacks
                opts.remote_cb = RemoteContext.createRemote
                opts.remote_cb_payload = callbacks.payload
                let code = git_clone(&repo, url, local.path, &opts)
                refused = code == GIT_EEXISTS.rawValue // its own emptiness check: someone wrote there after ours
                return code
            }
        } catch {
            git_repository_free(repo) // set if git_clone returned 0 and a callback still refused
            removeWhatCloneMade(created: created, in: local, refused: refused)
            throw error
        }
        return Repository(handle: repo!, path: local)
    }

    /// Throws unless `local` is missing or an empty directory. Makes the topmost missing directory itself (with a
    /// plain `mkdir`, so one another process makes first is never taken for ours) and returns it, the one to remove
    /// if the clone fails; nil when `local` already exists.
    private static func prepare(_ local: URL, for destination: URL) throws(GitError) -> URL? {
        let files = FileManager.default
        // Not `fileExists`, which follows symlinks: a dangling one must count as present, never be removed.
        func exists(_ url: URL) -> Bool {
            (try? files.attributesOfItem(atPath: url.path)) != nil
        }
        if exists(local) {
            guard (try? files.contentsOfDirectory(atPath: local.path))?.isEmpty == true else {
                throw .destinationNotEmpty(destination)
            }
            return nil
        }
        var top = local
        while !exists(top.deletingLastPathComponent()) {
            top.deleteLastPathComponent()
        }
        guard mkdir(top.path, 0o777) == 0 else {
            let reason = errno
            if reason == EEXIST { throw .destinationNotEmpty(destination) }
            let message = "cannot create \(top.path): \(String(cString: strerror(reason)))"
            throw .other(class: Int32(GIT_ERROR_OS.rawValue), code: -1, message: message)
        }
        return top
    }
}

/// A failed git_clone removes the directory it was cloning into, or for an existing one all of its contents
/// (libgit2's own cleanup, which cannot be narrowed); this removes the rest: the directory this call made, else a
/// `.git` left behind. When git_clone `refused` an existing destination that was no longer empty, it wrote nothing
/// there, so its `.git` is another process's and stays.
func removeWhatCloneMade(created: URL?, in local: URL, refused: Bool) {
    if let created {
        try? FileManager.default.removeItem(at: created)
    } else if !refused {
        try? FileManager.default.removeItem(at: local.appendingPathComponent(".git"))
    }
}
