import Foundation

/// An object id: a commit's, or (in a `RemoteRef`) the id of the tag object an annotated tag ref points at.
public struct CommitID: Hashable, Sendable {
    /// The 40-character lowercase hex SHA-1.
    public let hex: String
}

/// The name and email recorded as a commit's author and committer.
public struct Author: Sendable {
    /// The name shown in the log.
    public let name: String
    /// The email shown in the log.
    public let email: String

    /// An author with this `name` and `email`.
    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }
}

/// One commit as `log(from:to:limit:)` lists it. Author names and emails that are not valid UTF-8 are repaired with
/// U+FFFD, and a commit with a non-UTF-8 `encoding` header is not re-encoded the way git does.
public struct CommitSummary: Sendable, Equatable {
    /// The commit's object id.
    public let id: CommitID
    /// The message up to its first blank line, with line breaks inside that paragraph turned into spaces (what
    /// `git log --format=%s` prints); for the usual one-line subject, just that line.
    public let subject: String
    /// The author's name (not the committer's).
    public let authorName: String
    /// The author's email (not the committer's).
    public let authorEmail: String
    /// When the commit was made: the committer time, which is what `git log` orders by.
    public let date: Date
}

/// One ref a remote advertises, as `git ls-remote` prints it.
public struct RemoteRef: Sendable, Equatable {
    /// The full ref name: `HEAD`, `refs/heads/main`, `refs/tags/v1`, or a peeled tag `refs/tags/v1^{}`.
    public let name: String
    /// The object the ref points at (for a peeled `^{}` entry, the commit under the tag).
    public let id: CommitID
}
