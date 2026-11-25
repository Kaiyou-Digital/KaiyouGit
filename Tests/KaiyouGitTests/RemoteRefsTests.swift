import CLibGit2
import Foundation
@testable import KaiyouGit
import XCTest

/// `Repository.remoteRefs(url:auth:)` against local bare remotes built here; nothing touches the network.
final class RemoteRefsTests: XCTestCase {
    private let author = Author(name: "Test", email: "test@example.invalid")

    /// A bare remote holding `main` (one commit) pushed from a working repository, and that commit.
    private func makePushedRemote() async throws -> (remote: URL, commit: CommitID) {
        let remote = try Fixtures.makeBareRepository(for: self)
        let dir = try Fixtures.makeTempDir(for: self).appendingPathComponent("local")
        let repo = try await Repository.initialize(at: dir)
        try Fixtures.write("one", to: "a.md", in: dir)
        try await repo.stageAll()
        let commit = try await repo.commit(message: "one", author: author)
        try await repo.addRemote(name: "origin", url: remote.path)
        try await repo.push(refspec: "HEAD:refs/heads/main")
        return (remote, commit)
    }

    func testRemoteRefsListsBranchesTagsAndHead() async throws {
        let (remote, commit) = try await makePushedRemote()
        try Fixtures.tag("v1", at: "refs/heads/main", in: remote)
        let refs = try await Repository.remoteRefs(url: remote.path)
        XCTAssertEqual(refs.map(\.name), ["HEAD", "refs/heads/main", "refs/tags/v1"])
        XCTAssertEqual(Set(refs.map(\.id)), [commit])
    }

    /// An annotated tag in `dir` (a tag object, so the listing also carries the peeled `^{}` entry).
    private func annotatedTag(_ name: String, at rev: String, in dir: URL) throws {
        var repo: OpaquePointer?
        try check(git_repository_open(&repo, dir.path))
        defer { git_repository_free(repo) }
        var target: OpaquePointer?
        try check(git_revparse_single(&target, repo, rev))
        defer { git_object_free(target) }
        var signature: UnsafeMutablePointer<git_signature>?
        try check(git_signature_now(&signature, "Test", "test@example.invalid"))
        defer { git_signature_free(signature) }
        var oid = git_oid()
        try check(git_tag_create(&oid, repo, name, target, signature, "annotated\n", 1))
    }

    func testRemoteRefsListsAnnotatedTagAndItsPeeledEntry() async throws {
        let (remote, commit) = try await makePushedRemote()
        try annotatedTag("v2", at: "refs/heads/main", in: remote)
        let refs = try await Repository.remoteRefs(url: remote.path)
        XCTAssertEqual(refs.map(\.name), ["HEAD", "refs/heads/main", "refs/tags/v2", "refs/tags/v2^{}"])
        let peeled = refs.first { $0.name == "refs/tags/v2^{}" }
        XCTAssertEqual(peeled?.id, commit)
        let tagObject = refs.first { $0.name == "refs/tags/v2" }
        XCTAssertNotEqual(tagObject?.id, commit, "the tag ref points at the tag object, not the commit")
    }

    #if os(macOS)
        /// The listing is in `git ls-remote`'s order, not sorted: `v1^{}` follows `v1`, before `v1-rc`.
        func testRemoteRefsMatchGitLsRemoteLineForLine() async throws {
            let (remote, _) = try await makePushedRemote()
            try annotatedTag("v1", at: "refs/heads/main", in: remote)
            for name in ["v1-rc", "v1.0"] {
                try Fixtures.tag(name, at: "refs/heads/main", in: remote)
            }
            for name in ["B", "a"] {
                _ = try Fixtures.git(["branch", name, "main"], in: remote)
            }
            let expected = try Fixtures.gitLines(["ls-remote", remote.path], in: remote)
            let actual = try await Repository.remoteRefs(url: remote.path).map { "\($0.id.hex)\t\($0.name)" }
            XCTAssertEqual(actual, expected)
            XCTAssertTrue(actual.contains { $0.hasSuffix("refs/tags/v1^{}") })
        }
    #endif

    func testRemoteRefsOfMissingFileURLIsNotFound() async throws {
        let missing = try Fixtures.makeTempDir(for: self).appendingPathComponent("nothing here")
        let start = Date()
        await assertThrowsNotFound {
            try await Repository.remoteRefs(url: URL(fileURLWithPath: missing.path).absoluteString)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testRemoteRefsOfMissingPlainPathIsNotFound() async throws {
        let missing = try Fixtures.makeTempDir(for: self).appendingPathComponent("nothing here")
        let start = Date()
        await assertThrowsNotFound { try await Repository.remoteRefs(url: missing.path) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    /// Fails unless `body` throws `.notFound` with a message naming the missing path.
    private func assertThrowsNotFound(_ body: () async throws -> some Any) async {
        do {
            _ = try await body()
            XCTFail("expected .notFound")
        } catch {
            guard case let .notFound(message) = error as? GitError
            else { return XCTFail("expected .notFound, got \(error)") }
            XCTAssertTrue(message.contains("nothing here"), message)
        }
    }

    func testRemoteRefsOfNonRepositoryFolderIsOther() async throws {
        let folder = try Fixtures.makeTempDir(for: self)
        do {
            _ = try await Repository.remoteRefs(url: folder.path)
            XCTFail("expected a GitError")
        } catch {
            guard case let .other(errorClass, _, _) = error as? GitError else {
                return XCTFail("expected .other, got \(error)")
            }
            XCTAssertEqual(errorClass, Int32(GIT_ERROR_REPOSITORY.rawValue))
        }
    }

    func testRemoteRefsRefusedConnectionIsOtherOSError() async throws {
        let auth = RemoteAuth(
            credentials: .sshKey(user: "git", privateKey: SSHIntegrationTests.makeUnknownKey(), passphrase: nil),
            hostKeys: .pinned(sha256: ["AAAA"])
        )
        do {
            _ = try await Repository.remoteRefs(url: "ssh://git@127.0.0.1:1/x.git", auth: auth)
            XCTFail("expected a GitError")
        } catch {
            guard case let .other(errorClass, _, message) = error as? GitError else {
                return XCTFail("expected .other, got \(error)")
            }
            XCTAssertEqual(errorClass, Int32(GIT_ERROR_OS.rawValue))
            XCTAssertTrue(message.contains("Connection refused"), message)
        }
    }

    func testRemoteRefsOfEmptyRemoteIsEmptyArray() async throws {
        let remote = try Fixtures.makeBareRepository(for: self)
        let refs = try await Repository.remoteRefs(url: remote.path)
        XCTAssertEqual(refs, [])
    }

    func testRemoteRefsHTTPSIsUnsupportedBeforeConnecting() async {
        await assertThrows(.unsupportedTransport("https")) {
            try await Repository.remoteRefs(url: "https://example.invalid/x.git")
        }
    }

    func testRemoteRefsSSHWithoutAuthIsRefused() async {
        await assertThrows(.authenticationFailed) {
            try await Repository.remoteRefs(url: "ssh://git@example.invalid/x.git")
        }
        await assertThrows(.authenticationFailed) {
            try await Repository.remoteRefs(url: "git@example.invalid:x.git")
        }
    }

    func testRemoteRefsLeavesNoConfigBehind() async throws {
        let (remote, _) = try await makePushedRemote()
        let config = remote.appendingPathComponent("config")
        let before = try Data(contentsOf: config)
        _ = try await Repository.remoteRefs(url: remote.path)
        XCTAssertEqual(try Data(contentsOf: config), before)
    }

    func testRemoteRefsCancelledTaskThrowsCancelled() async throws {
        let (remote, _) = try await makePushedRemote()
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return try await Repository.remoteRefs(url: remote.path)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected .cancelled")
        } catch {
            XCTAssertEqual(error as? GitError, .cancelled)
        }
    }
}
