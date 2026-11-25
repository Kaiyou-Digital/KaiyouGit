import CLibGit2
import Foundation

/// An open git repository (a working tree and its `.git`). Calls on one repository run one at a time, on the
/// repository's own serial executor.
public actor Repository {
    /// `nonisolated(unsafe)` so `deinit` can free it; it is set once and only used from this actor.
    nonisolated(unsafe) let handle: OpaquePointer
    /// The working tree this repository was opened, initialised or cloned at.
    public let path: URL

    /// Every isolated method runs here, one job at a time. Invariant every method must keep: never `await` while it is
    /// using `handle`, since a suspension lets another call run on it; that is what keeps libgit2 calls on `handle`
    /// serial. A long fetch or push blocks this queue (later calls wait) rather than a cooperative-pool thread.
    private let queue = DispatchSerialQueue(label: "digital.kaiyou.KaiyouGit.repository")
    /// The repository's own serial queue, so calls (network ones included) wait their turn rather than overlap.
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    init(handle: OpaquePointer, path: URL) {
        self.handle = handle
        self.path = path
    }

    deinit { git_repository_free(handle) }

    /// Opens the existing repository whose working tree is `url`; throws `.notFound` when there is none.
    public static func open(at url: URL) async throws -> Repository {
        try LibGit2.ensureInitialized()
        var repo: OpaquePointer?
        try check(git_repository_open(&repo, url.path))
        return Repository(handle: repo!, path: url)
    }

    /// Creates `url` (and any missing parents) as a repository whose first branch is `branch`.
    public static func initialize(at url: URL, branch: String = "main") async throws -> Repository {
        try LibGit2.ensureInitialized()
        var opts = git_repository_init_options()
        try check(git_repository_init_options_init(&opts, UInt32(GIT_REPOSITORY_INIT_OPTIONS_VERSION)))
        opts.flags = GIT_REPOSITORY_INIT_MKPATH.rawValue
        var repo: OpaquePointer?
        // Returns the code, not throws(GitError): a typed-throws closure crashes the Xcode 26.6 compiler.
        let code = branch.withCString { name -> Int32 in
            opts.initial_head = name
            return git_repository_init_ext(&repo, url.path, &opts)
        }
        try check(code)
        return Repository(handle: repo!, path: url)
    }
}
