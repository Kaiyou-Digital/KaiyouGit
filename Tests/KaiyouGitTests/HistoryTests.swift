import CLibGit2
import Foundation
@testable import KaiyouGit
import XCTest

final class HistoryTests: XCTestCase {
    private let author = Author(name: "Test", email: "test@example.invalid")

    private func makeRepo() async throws -> (Repository, URL) {
        let dir = try Fixtures.makeTempDir(for: self).appendingPathComponent("repo")
        return try await (Repository.initialize(at: dir, branch: "main"), dir)
    }

    @discardableResult
    private func commitAll(_ repo: Repository, _ message: String = "edit") async throws -> CommitID {
        try await repo.stageAll()
        return try await repo.commit(message: message, author: author)
    }

    /// Two commits: `archive/a.md`, `archive-old/x.md`, `other.md` and `del.md`, then each changed in turn.
    private func makeTwoCommits() async throws -> (Repository, URL) {
        let (repo, dir) = try await makeRepo()
        for name in ["archive/a.md", "archive/sub/b.md", "archive-old/x.md", "other.md", "del.md"] {
            try Fixtures.write("1", to: name, in: dir)
        }
        try await commitAll(repo, "seed")
        try Fixtures.write("2", to: "archive/a.md", in: dir) // modified
        try Fixtures.write("2", to: "archive/sub/b.md", in: dir)
        try Fixtures.write("2", to: "archive-old/x.md", in: dir)
        try Fixtures.write("new", to: "added.md", in: dir) // added
        try FileManager.default.removeItem(at: dir.appendingPathComponent("del.md")) // deleted
        try await commitAll(repo, "change")
        return (repo, dir)
    }

    private func assertNotFound(
        _ body: () async throws -> some Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await body()
            XCTFail("expected notFound", file: file, line: line)
        } catch let error as GitError {
            guard case .notFound = error else { return XCTFail("wrong error \(error)", file: file, line: line) }
        } catch {
            XCTFail("wrong error \(error)", file: file, line: line)
        }
    }

    func testChangedPathsBetweenCommitsListsAddedModifiedDeleted() async throws {
        let (repo, _) = try await makeTwoCommits()
        let names = try await repo.changedPaths(from: "HEAD~1", to: "HEAD")
        XCTAssertEqual(names, ["added.md", "archive-old/x.md", "archive/a.md", "archive/sub/b.md", "del.md"])
    }

    func testChangedPathsBetweenCommitsDirectoryPathspecAndSiblingPrefix() async throws {
        let (repo, _) = try await makeTwoCommits()
        let directory = try await repo.changedPaths(from: "HEAD~1", to: "HEAD", under: ["archive"])
        XCTAssertEqual(directory, ["archive/a.md", "archive/sub/b.md"])
        let both = try await repo.changedPaths(from: "HEAD~1", to: "HEAD", under: ["archive/sub", "del.md"])
        XCTAssertEqual(both, ["archive/sub/b.md", "del.md"])
    }

    func testChangedPathsBetweenCommitsDotAndDotSlashSpellings() async throws {
        let (repo, _) = try await makeTwoCommits()
        let everything = try await repo.changedPaths(from: "HEAD~1", to: "HEAD")
        let dot = try await repo.changedPaths(from: "HEAD~1", to: "HEAD", under: ["."])
        XCTAssertEqual(dot, everything)
        for spelling in ["./archive", "archive/.", "archive/", "./archive/."] {
            let names = try await repo.changedPaths(from: "HEAD~1", to: "HEAD", under: [spelling])
            XCTAssertEqual(names, ["archive/a.md", "archive/sub/b.md"], spelling)
        }
    }

    func testChangedPathsBetweenIdenticalCommitsIsEmpty() async throws {
        let (repo, _) = try await makeTwoCommits()
        let names = try await repo.changedPaths(from: "HEAD", to: "HEAD")
        XCTAssertEqual(names, [])
    }

    func testChangedPathsBetweenCommitsReversedOrderStillDiffs() async throws {
        let (repo, _) = try await makeTwoCommits()
        let forward = try await repo.changedPaths(from: "HEAD~1", to: "HEAD")
        let reversed = try await repo.changedPaths(from: "HEAD", to: "HEAD~1")
        XCTAssertEqual(reversed, forward)
        XCTAssertFalse(reversed.isEmpty)
    }

    func testChangedPathsBetweenCommitsRenameIsTwoPaths() async throws {
        let (repo, dir) = try await makeRepo()
        try Fixtures.write("same content, long enough to be a clear rename", to: "old name.md", in: dir)
        try await commitAll(repo)
        try FileManager.default.moveItem(
            at: dir.appendingPathComponent("old name.md"), to: dir.appendingPathComponent("new name.md")
        )
        try await commitAll(repo)
        let names = try await repo.changedPaths(from: "HEAD~1", to: "HEAD")
        XCTAssertEqual(names, ["new name.md", "old name.md"])
    }

    func testChangedPathsBetweenCommitsUnknownRevIsNotFound() async throws {
        let (repo, _) = try await makeTwoCommits()
        await assertNotFound { try await repo.changedPaths(from: "nope", to: "HEAD") }
        await assertNotFound { try await repo.changedPaths(from: "HEAD", to: "nope") }
    }

    func testChangedPathsBetweenCommitsWithUpstreamSpelling() async throws {
        let (repo, dir) = try await makeRepo()
        try Fixtures.write("1", to: "a.md", in: dir)
        let base = try await commitAll(repo)
        var oid = git_oid()
        XCTAssertEqual(git_oid_fromstr(&oid, base.hex), 0)
        var ref: OpaquePointer?
        XCTAssertEqual(git_reference_create(&ref, repo.handle, "refs/remotes/origin/main", &oid, 1, nil), 0)
        git_reference_free(ref)
        try await repo.addRemote(name: "origin", url: "/nowhere")
        try await repo.setConfig("branch.main.remote", "origin")
        try await repo.setConfig("branch.main.merge", "refs/heads/main")
        try Fixtures.write("2", to: "a.md", in: dir)
        try Fixtures.write("2", to: "b.md", in: dir)
        try await commitAll(repo)
        let names = try await repo.changedPaths(from: "@{u}", to: "HEAD")
        XCTAssertEqual(names, ["a.md", "b.md"])
        let named = try await repo.changedPaths(from: "origin/main", to: "main")
        XCTAssertEqual(named, names)
    }
}
