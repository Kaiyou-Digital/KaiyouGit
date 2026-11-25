import CLibGit2
import Foundation
@testable import KaiyouGit
import XCTest

final class WorkingTreeTests: XCTestCase {
    private let author = Author(name: "Test", email: "test@example.invalid")

    private func makeRepo() async throws -> (Repository, URL) {
        let dir = try Fixtures.makeTempDir(for: self).appendingPathComponent("repo")
        return try await (Repository.initialize(at: dir), dir)
    }

    /// Number of parents of the commit `id`, read straight from libgit2.
    private func parentCount(_ id: CommitID, in repo: Repository) throws -> UInt32 {
        var oid = git_oid()
        XCTAssertEqual(git_oid_fromstr(&oid, id.hex), 0)
        var commit: OpaquePointer?
        XCTAssertEqual(git_commit_lookup(&commit, repo.handle, &oid), 0)
        defer { git_commit_free(commit) }
        return git_commit_parentcount(commit)
    }

    private func entry(_ path: String, _ index: Change?, _ workingTree: Change?) -> StatusEntry {
        StatusEntry(path: path, index: index, workingTree: workingTree)
    }

    func testStatusReportsUntrackedModifiedAndStaged() async throws {
        let (repo, dir) = try await makeRepo()
        try Fixtures.write("1", to: "a.md", in: dir)
        try Fixtures.write("1", to: "b.md", in: dir)
        try Fixtures.write("1", to: "gone.md", in: dir)
        try await repo.stageAll()
        try await repo.commit(message: "first", author: author)

        try Fixtures.write("2", to: "a.md", in: dir) // modified, unstaged
        try Fixtures.write("2", to: "b.md", in: dir)
        try await repo.stage(paths: ["b.md"]) // modified, staged
        try FileManager.default.removeItem(at: dir.appendingPathComponent("gone.md")) // deleted, unstaged
        try Fixtures.write("n", to: "new.md", in: dir)
        try await repo.stage(paths: ["new.md"]) // added, staged
        try Fixtures.write("u", to: "sub/dir/untracked.md", in: dir) // listed individually

        let all = try await repo.status()
        XCTAssertEqual(all, [
            entry("a.md", nil, .modified),
            entry("b.md", .modified, nil),
            entry("gone.md", nil, .deleted),
            entry("new.md", .added, nil),
            entry("sub/dir/untracked.md", nil, .untracked),
        ])
        let only = try await repo.status(paths: ["a.md"])
        XCTAssertEqual(only, [entry("a.md", nil, .modified)])
    }

    func testCommitWithPathsLeavesOtherStagedFilesStaged() async throws {
        let (repo, dir) = try await makeRepo()
        try Fixtures.write("1", to: "a", in: dir)
        try Fixtures.write("1", to: "b", in: dir)
        try await repo.stageAll()
        try await repo.commit(message: "base", author: author)

        try Fixtures.write("2", to: "a", in: dir)
        try Fixtures.write("2", to: "b", in: dir)
        try await repo.stage(paths: ["a", "b"])
        try await repo.commit(message: "only a", author: author, paths: ["a"])

        let after = try await repo.status()
        XCTAssertEqual(after, [entry("b", .modified, nil)])
    }

    func testCommitWithPathsCommitsUnstagedWorkingTreeChanges() async throws {
        let (repo, dir) = try await makeRepo()
        try Fixtures.write("1", to: "a", in: dir)
        try Fixtures.write("1", to: "b", in: dir)
        try await repo.stageAll()
        try await repo.commit(message: "base", author: author)

        try Fixtures.write("2", to: "a", in: dir)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("b"))
        try await repo.commit(message: "a and b", author: author, paths: ["a", "b"])
        let after = try await repo.status()
        XCTAssertEqual(after, [])
    }

    func testCommitNothingThrows() async throws {
        let (repo, dir) = try await makeRepo()
        let nothing = GitError.nothingToCommit
        do {
            try await repo.commit(message: "empty", author: author)
            XCTFail("expected an error")
        } catch { XCTAssertEqual(error as? GitError, nothing) }

        try Fixtures.write("1", to: "a", in: dir)
        try await repo.stageAll()
        try await repo.commit(message: "base", author: author)
        do {
            try await repo.commit(message: "again", author: author)
            XCTFail("expected an error")
        } catch { XCTAssertEqual(error as? GitError, nothing) }
        do {
            try await repo.commit(message: "again", author: author, paths: ["a"])
            XCTFail("expected an error")
        } catch { XCTAssertEqual(error as? GitError, nothing) }
    }

    func testIsIgnoredHonoursGitignore() async throws {
        let (repo, dir) = try await makeRepo()
        try Fixtures.write("*.log\nbuild/\n", to: ".gitignore", in: dir)
        let log = try await repo.isIgnored("debug.log")
        let built = try await repo.isIgnored("build/out.txt")
        let kept = try await repo.isIgnored("notes.md")
        XCTAssertTrue(log)
        XCTAssertTrue(built)
        XCTAssertFalse(kept)
    }

    func testCheckoutPathsRestoresFile() async throws {
        let (repo, dir) = try await makeRepo()
        try Fixtures.write("1", to: "a", in: dir)
        try Fixtures.write("1", to: "b", in: dir)
        try await repo.stageAll()
        try await repo.commit(message: "base", author: author)

        try Fixtures.write("2", to: "a", in: dir)
        try Fixtures.write("2", to: "b", in: dir)
        try await repo.stage(paths: ["a"])
        try await repo.checkout(paths: ["a"])
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("a"), encoding: .utf8), "1")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("b"), encoding: .utf8), "2")
        let after = try await repo.status()
        XCTAssertEqual(after, [entry("b", nil, .modified)])
    }

    func testResetHardDiscardsChanges() async throws {
        let (repo, dir) = try await makeRepo()
        try Fixtures.write("1", to: "a", in: dir)
        try await repo.stageAll()
        try await repo.commit(message: "base", author: author)

        try Fixtures.write("2", to: "a", in: dir)
        try Fixtures.write("n", to: "new", in: dir)
        try Fixtures.write("u", to: "untracked", in: dir)
        try await repo.stage(paths: ["a", "new"]) // like git, reset --hard also deletes a staged new file
        try await repo.resetHard()
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("a"), encoding: .utf8), "1")
        let after = try await repo.status()
        XCTAssertEqual(after, [entry("untracked", nil, .untracked)])
    }

    func testPathsWithSpacesAndUnicode() async throws {
        let (repo, dir) = try await makeRepo()
        let path = "My Notes/café 写真.md"
        try Fixtures.write("hello", to: path, in: dir)
        let untracked = try await repo.status()
        XCTAssertEqual(untracked, [entry(path, nil, .untracked)])

        try await repo.stage(paths: [path])
        let staged = try await repo.status(paths: [path])
        XCTAssertEqual(staged, [entry(path, .added, nil)])

        try await repo.commit(message: "unicode", author: author, paths: [path])
        let clean = try await repo.status()
        XCTAssertEqual(clean, [])

        try Fixtures.write("changed", to: path, in: dir)
        let modified = try await repo.status()
        XCTAssertEqual(modified, [entry(path, nil, .modified)])
    }

    func testEmptyRepository() async throws {
        let (repo, dir) = try await makeRepo()
        try Fixtures.write("1", to: "a", in: dir)
        try Fixtures.write("1", to: "b", in: dir)
        let fresh = try await repo.status()
        XCTAssertEqual(fresh, [entry("a", nil, .untracked), entry("b", nil, .untracked)])

        try await repo.stageAll()
        try await repo.unstage(paths: ["a"])
        let afterUnstage = try await repo.status()
        XCTAssertEqual(afterUnstage, [entry("a", nil, .untracked), entry("b", .added, nil)])

        let id = try await repo.commit(message: "root", author: author)
        XCTAssertEqual(try parentCount(id, in: repo), 0)
        let after = try await repo.status()
        XCTAssertEqual(after, [entry("a", nil, .untracked)])

        let second = try await repo.commit(message: "second", author: author, paths: ["a"])
        XCTAssertEqual(try parentCount(second, in: repo), 1)
    }

    func testUnstageWithCommitResetsToHead() async throws {
        let (repo, dir) = try await makeRepo()
        try Fixtures.write("1", to: "a", in: dir)
        try await repo.stageAll()
        try await repo.commit(message: "base", author: author)
        try Fixtures.write("2", to: "a", in: dir)
        try await repo.stage(paths: ["a"])
        try await repo.unstage(paths: ["a"])
        let after = try await repo.status()
        XCTAssertEqual(after, [entry("a", nil, .modified)])
    }

    /// With `.git/index.lock` held, the commit still lands but the index file cannot be saved.
    func testCommitWhoseIndexWriteFailsThrowsTypedErrorWithTheCommit() async throws {
        for scoped in [false, true] {
            let (repo, dir) = try await makeRepo()
            try Fixtures.write("1", to: "a.md", in: dir)
            try await repo.stageAll()
            try await repo.commit(message: "base", author: author)
            try Fixtures.write("2", to: "a.md", in: dir)
            try Fixtures.write("n", to: "dir/new.md", in: dir)
            let paths: [String]? = scoped ? ["dir", "a.md"] : nil
            if !scoped { try await repo.stageAll() } // before the lock: staging writes the index itself
            let lock = dir.appendingPathComponent(".git/index.lock")
            try "".write(to: lock, atomically: true, encoding: .utf8)
            do {
                try await repo.commit(message: "m", author: author, paths: paths)
                XCTFail("expected commitCreatedButIndexNotSaved (scoped: \(scoped))")
            } catch let GitError.commitCreatedButIndexNotSaved(commit, reason) {
                let head = try await repo.resolve("HEAD")
                XCTAssertEqual(head, commit)
                XCTAssertFalse(reason.isEmpty)
            }
            // A fresh instance reads the index from disk, which only a path-scoped commit leaves stale.
            let before = try await Repository.open(at: dir).status()
            if scoped {
                XCTAssertFalse(before.isEmpty, "a fresh instance sees the commit's paths reversed")
            } else {
                XCTAssertEqual(before, [], "an unscoped commit leaves nothing stale")
            }
            try FileManager.default.removeItem(at: lock)
            try await repo.stageAll()
            let status = try await Repository.open(at: dir).status()
            XCTAssertEqual(status, [], "stageAll repairs the index on disk (scoped: \(scoped))")
        }
    }
}
