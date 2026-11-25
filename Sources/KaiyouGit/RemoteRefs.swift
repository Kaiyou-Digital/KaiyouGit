import CLibGit2
import Foundation

/// Listing a remote without a local repository.
public extension Repository {
    /// `git ls-remote url`: every ref the remote advertises (`HEAD`, `refs/heads/*`, `refs/tags/*`, and peeled
    /// `refs/tags/x^{}` entries as git prints them), in the order `git ls-remote` prints them (the server's
    /// advertisement order over ssh). An empty remote returns `[]` (libgit2 drops the placeholder line an empty
    /// repository advertises; checked live against an empty GitHub repository over ssh), which is not an error.
    /// Needs no repository and writes nothing to any config or disk.
    ///
    /// `url` is held to the same rules as `fetch`: `ssh://` and scp-style URLs need `auth`, `file://` and local
    /// paths need none, any other scheme (https and http included) throws `.unsupportedTransport`, and an ssh URL
    /// without `auth` throws `.authenticationFailed`, both before anything connects. `url.<base>.insteadOf`
    /// rewrites are not applied (the call reads no configuration).
    ///
    /// A local path (plain or `file://`) that does not exist throws `.notFound` naming it, before connecting. A
    /// folder that exists but is not a repository throws `.other` (libgit2's repository error class), and a
    /// refused connection throws `.other` (the OS error class, with the system's message). A host key the
    /// `HostKeyPolicy` does not trust throws `.hostKeyRejected`, a refused key `.authenticationFailed`, and an ssh
    /// session that fails after connecting `.network`. A task cancelled before the call throws `.cancelled`. The
    /// call runs on a dispatch queue of its own, not Swift's cooperative pool. There is no cancellation or timeout
    /// once a connection stalls before the first byte (this call has no progress ticks to notice cancellation at),
    /// so a black-holed host holds the call until the operating system gives up.
    static func remoteRefs(url: String, auth: RemoteAuth? = nil) async throws -> [RemoteRef] {
        try await RefsRunner().list(url: url, auth: auth)
    }
}

/// Runs the listing on a dispatch queue of its own, like `CloneRunner`, still inside the calling task.
private actor RefsRunner {
    private let queue = DispatchSerialQueue(label: "digital.kaiyou.KaiyouGit.remoteRefs")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    func list(url: String, auth: RemoteAuth?) throws(GitError) -> [RemoteRef] {
        try LibGit2.ensureInitialized()
        try requireSupportedTransport(url, auth: auth)
        if Task.isCancelled { throw .cancelled }
        if let path = localPath(of: url), !FileManager.default.fileExists(atPath: path) {
            throw .notFound("no repository at '\(path)': no such file or directory")
        }
        var remote: OpaquePointer?
        try check(git_remote_create_detached(&remote, url))
        defer { git_remote_free(remote) }
        try RemoteContext(auth: auth, progress: nil).run { callbacks in
            var callbacks = callbacks
            return git_remote_connect(remote, GIT_DIRECTION_FETCH, &callbacks, nil, nil)
        }
        defer { git_remote_disconnect(remote) }
        var heads: UnsafeMutablePointer<UnsafePointer<git_remote_head>?>?
        var count = 0
        try check(git_remote_ls(&heads, &count, remote))
        var refs: [RemoteRef] = []
        for index in 0 ..< count {
            guard var head = heads?[index]?.pointee, let name = head.name else { continue }
            refs.append(RemoteRef(
                name: String(cString: name),
                id: CommitID(hex: String(cString: git_oid_tostr_s(&head.oid)))
            ))
        }
        return refs
    }
}
