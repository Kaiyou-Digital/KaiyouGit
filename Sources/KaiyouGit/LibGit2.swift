import CLibGit2

/// Process-wide libgit2 setup and build facts.
public enum LibGit2 {
    /// Initialises libgit2 once; later calls (from any thread) are no-ops.
    public static func initialize() {
        _ = initResult
    }

    /// What the ssh transport is built on in this libgit2 (expected "libssh2").
    public static var sshBackend: String { backend(GIT_FEATURE_SSH) }

    /// What the https transport is built on in this libgit2 (expected "openssl").
    public static var httpsBackend: String { backend(GIT_FEATURE_HTTPS) }

    /// Throws if the one `git_libgit2_init()` call failed.
    static func ensureInitialized() throws(GitError) {
        if initResult < 0 { throw .other(class: 0, code: initResult, message: "git_libgit2_init failed") }
    }

    /// A `static let` is initialised exactly once, thread-safely, by the runtime.
    private static let initResult: Int32 = git_libgit2_init()

    private static func backend(_ feature: git_feature_t) -> String {
        initialize()
        return git_libgit2_feature_backend(feature).map { String(cString: $0) } ?? "none"
    }
}
