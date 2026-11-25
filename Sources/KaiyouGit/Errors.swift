import CLibGit2
import Foundation

/// What went wrong in a call. Anything without its own case is `.other`, with libgit2's own class, code and message.
public enum GitError: Error, Equatable, Sendable {
    /// Sign-in failed: the server refused the key, no `auth` was given for an ssh URL, or libssh2 could not use the
    /// key text (a malformed key, a wrong passphrase).
    case authenticationFailed
    /// The server's host key was not trusted by the `HostKeyPolicy`.
    case hostKeyRejected
    /// The branches have diverged, or the remote refused a push because it is not a fast-forward.
    case notFastForward
    /// A checkout would overwrite uncommitted changes to a file; nothing was changed.
    case wouldOverwriteLocalChanges
    /// A revision, path, remote or reference does not exist; the message says which.
    case notFound(String)
    /// A connection or ssh-session failure, with libgit2's message.
    case network(String)
    /// The calling task was cancelled during a transfer.
    case cancelled
    /// The URL's scheme is not supported (https and http are not); the associated value is the scheme.
    case unsupportedTransport(String)
    /// `clone`'s destination exists and is not empty; it was not touched.
    case destinationNotEmpty(URL)
    /// `commit` found nothing to commit: the index (or the given paths) matches HEAD, or `paths` was empty.
    case nothingToCommit
    /// `commit` created the commit and moved HEAD, but could not save the index file (a full disk, a stuck
    /// `index.lock`). `reason` is libgit2's message. Do not retry the commit: it exists, and a retry would find nothing
    /// to commit. Only a path-scoped commit leaves the index on disk stale: other `Repository` instances (and the git
    /// CLI) see those paths reversed as staged changes until the cause is gone (for example a stale `index.lock` is
    /// removed) and `stage` or `stageAll` is called for them.
    case commitCreatedButIndexNotSaved(commit: CommitID, reason: String)
    /// The operation needs a branch and HEAD is detached.
    case detachedHead
    /// Any other libgit2 failure.
    case other(class: Int32, code: Int32, message: String)
}

/// Pure mapping from a libgit2 return code, error class and message to a `GitError`.
func mapError(code: Int32, errorClass: Int32, message: String) -> GitError {
    switch code {
    case GIT_EAUTH.rawValue: return .authenticationFailed
    case GIT_ECERTIFICATE.rawValue: return .hostKeyRejected
    case GIT_ENONFASTFORWARD.rawValue: return .notFastForward
    case GIT_ECONFLICT.rawValue: return .wouldOverwriteLocalChanges
    case GIT_ENOTFOUND.rawValue: return .notFound(message)
    case GIT_EUSER.rawValue: return .cancelled
    default:
        // libssh2 refusing the key itself (bad format, wrong passphrase) is a sign-in failure. libgit2 puts the same
        // prefix on every other libssh2 failure while signing in, a dropped socket included, which stays network.
        let signIn = "failed to authenticate SSH session"
        if errorClass == Int32(GIT_ERROR_SSH.rawValue), message.hasPrefix(signIn) {
            let detail = message.dropFirst(signIn.count).lowercased()
            if ["private key", "passphrase", "key data"].contains(where: { detail.contains($0) }) {
                return .authenticationFailed
            }
        }
        let networkClasses = [GIT_ERROR_NET, GIT_ERROR_SSH, GIT_ERROR_HTTP].map { Int32($0.rawValue) }
        if networkClasses.contains(errorClass) { return .network(message) }
        return .other(class: errorClass, code: code, message: message)
    }
}

/// Throws the mapped error when `rc` is negative, reading libgit2's last error for the detail.
func check(_ code: Int32) throws(GitError) {
    guard code < 0 else { return }
    let last = git_error_last()
    let message = last.map { String(cString: $0.pointee.message) } ?? "no message"
    throw mapError(code: code, errorClass: last?.pointee.klass ?? 0, message: message)
}
