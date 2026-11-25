import CLibGit2
import Foundation
@testable import KaiyouGit
import XCTest

/// Directory checkout, stale index, path spellings and typed errors for the working-tree operations.
final class CheckoutAndIndexTests: XCTestCase {
    private let author = Author(name: "Test", email: "test@example.invalid")

    /// HEAD~1 has dir/old.md and a.md; HEAD adds dir/later.md.
    private func makeRepo() async throws -> (Repository, URL) {
        let dir = try Fixtures.makeTempDir(for: self).appendingPathComponent("r")
        let repo = try await Repository.initialize(at: dir)
        try Fixtures.write("1", to: "a.md", in: dir)
        try Fixtures.write("1", to: "dir/old.md", in: dir)
        try await repo.stageAll()
        try await repo.commit(message: "one", author: author)
        try Fixtures.write("2", to: "dir/later.md", in: dir)
        try await repo.stageAll()
        try await repo.commit(message: "two", author: author)
        return (repo, dir)
    }

    private func staged(_ repo: Repository) async throws -> [String] {
        try await repo.status().filter { $0.index != nil }.map(\.path)
    }

    private func read(_ name: String, in dir: URL) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    // MARK: C1, checkout of a directory

    func testCheckoutDirectoryKeepsStagedNewFile() async throws {
        let (repo, dir) = try await makeRepo()
        try Fixtures.write("precious", to: "dir/new.md", in: dir)
        try await repo.stage(paths: ["dir/new.md"])
        try Fixtures.write("edited", to: "dir/old.md", in: dir)
        try await repo.checkout(paths: ["dir"])
        XCTAssertEqual(read("dir/new.md", in: dir), "precious")
        XCTAssertEqual(read("dir/old.md", in: dir), "1")
        let after = try await repo.status()
        XCTAssertEqual(after, [StatusEntry(path: "dir/new.md", index: .added, workingTree: nil)])
    }

    func testCheckoutDirectoryFromOlderRevKeepsFilesTheRevLacks() async throws {
        let (repo, dir) = try await makeRepo()
        try Fixtures.write("unsaved", to: "dir/later.md", in: dir)
        try Fixtures.write("untracked", to: "dir/u.md", in: dir)
        try await repo.checkout(paths: ["dir"], from: "HEAD~1")
        XCTAssertEqual(read("dir/later.md", in: dir), "unsaved")
        XCTAssertEqual(read("dir/u.md", in: dir), "untracked")
        XCTAssertEqual(read("dir/old.md", in: dir), "1")
    }

    func testCheckoutEmptyPathNeverMeansEverything() async throws {
        let (repo, dir) = try await makeRepo()
        try Fixtures.write("edited", to: "a.md", in: dir)
        do {
            try await repo.checkout(paths: [""])
            XCTFail("expected an error")
        } catch {}
        XCTAssertEqual(read("a.md", in: dir), "edited")
    }

    // MARK: I1, an index changed elsewhere

    func testStageKeepsStagingDoneThroughAnotherInstance() async throws {
        let (repoA, dir) = try await makeRepo()
        let repoB = try await Repository.open(at: dir)
        _ = try await repoA.status()
        try Fixtures.write("x", to: "x.md", in: dir)
        try Fixtures.write("y", to: "y.md", in: dir)
        try await repoB.stage(paths: ["x.md"])
        try await repoA.stage(paths: ["y.md"])
        let fresh = try await Repository.open(at: dir)
        let names = try await staged(fresh)
        XCTAssertEqual(names, ["x.md", "y.md"])
    }

    func testCommitSeesStagingDoneThroughAnotherInstance() async throws {
        let (repoA, dir) = try await makeRepo()
        let repoB = try await Repository.open(at: dir)
        _ = try await repoA.status()
        try Fixtures.write("x", to: "x.md", in: dir)
        try await repoB.stage(paths: ["x.md"])
        try await repoA.commit(message: "x", author: author)
        let after = try await repoB.status()
        XCTAssertEqual(after, [])
    }

    func testUnstageAndScopedCommitKeepStagingDoneElsewhere() async throws {
        let (repoA, dir) = try await makeRepo()
        let repoB = try await Repository.open(at: dir)
        _ = try await repoA.status()
        try Fixtures.write("x", to: "x.md", in: dir)
        try await repoB.stage(paths: ["x.md"])
        try await repoA.unstage(paths: ["a.md"])
        var names = try await staged(Repository.open(at: dir))
        XCTAssertEqual(names, ["x.md"])

        _ = try await repoA.status()
        try Fixtures.write("y", to: "y.md", in: dir)
        try await repoB.stage(paths: ["y.md"])
        try Fixtures.write("9", to: "a.md", in: dir)
        try await repoA.commit(message: "a", author: author, paths: ["a.md"])
        names = try await staged(Repository.open(at: dir))
        XCTAssertEqual(names, ["x.md", "y.md"])
    }

    // MARK: Minor 2, `./x` and `x/.`

    func testDotSlashAndTrailingDotSpellingsActLikePlainPaths() async throws {
        let (repo, dir) = try await makeRepo()
        try Fixtures.write("3", to: "dir/old.md", in: dir)
        for spelling in ["./dir/old.md", "dir/.", "./dir/", "./dir/."] {
            let listed = try await repo.status(paths: [spelling])
            XCTAssertEqual(listed.map(\.path), ["dir/old.md"], spelling)
            let changed = try await repo.changedPaths(against: "HEAD", under: [spelling])
            XCTAssertEqual(changed, ["dir/old.md"], spelling)
        }
        try await repo.stage(paths: ["./dir/old.md"])
        var names = try await staged(repo)
        XCTAssertEqual(names, ["dir/old.md"])
        try await repo.unstage(paths: ["dir/."])
        names = try await staged(repo)
        XCTAssertEqual(names, [])
        try await repo.commit(message: "m", author: author, paths: ["./dir/."])
        let clean = try await repo.status()
        XCTAssertEqual(clean, [])
        try Fixtures.write("4", to: "dir/old.md", in: dir)
        try await repo.checkout(paths: ["./dir/."])
        XCTAssertEqual(read("dir/old.md", in: dir), "3")
    }

    // MARK: Minor 3, 4, 6

    func testIsIgnoredThrowsOutsideTheWorkingTree() async throws {
        let (repo, dir) = try await makeRepo()
        try Fixtures.write("*.log\n", to: ".gitignore", in: dir)
        let log = try await repo.isIgnored("x.log")
        XCTAssertTrue(log)
        for path in ["../x.log", "/abs/x.log"] {
            do {
                _ = try await repo.isIgnored(path)
                XCTFail("expected an error for \(path)")
            } catch {}
        }
    }

    func testIsIgnoredRejectsDotAndDotDotComponents() async throws {
        let (repo, dir) = try await makeRepo()
        try Fixtures.write("*.log\n", to: ".gitignore", in: dir)
        for path in [".", "x/..", "../x", "a/../b", "/abs/x", "..", "a/b/..", "a/./b.txt", ""] {
            await assertThrowsGitError { try await repo.isIgnored(path) }
        }
        let plain = try await repo.isIgnored("a/b.txt")
        XCTAssertFalse(plain)
        let log = try await repo.isIgnored("./a/b.log")
        XCTAssertTrue(log)
    }

    func testNothingToCommitAndDetachedHeadAreTyped() async throws {
        let (repo, _) = try await makeRepo()
        await assertThrows(.nothingToCommit) { try await repo.commit(message: "m", author: self.author) }
        await assertThrows(.nothingToCommit) { try await repo.commit(message: "m", author: self.author, paths: []) }
        try await repo.detach()
        await assertThrows(.detachedHead) { try await repo.fastForward(to: "HEAD") }
    }

    func testCommitThatLandedButCouldNotSaveTheIndexIsNotReversed() async throws {
        let (repo, dir) = try await makeRepo()
        try Fixtures.write("9", to: "a.md", in: dir)
        try "".write(to: dir.appendingPathComponent(".git/index.lock"), atomically: true, encoding: .utf8)
        do {
            try await repo.commit(message: "a", author: author, paths: ["a.md"])
            XCTFail("expected the index write to fail")
        } catch GitError.commitCreatedButIndexNotSaved {}
        let head = try await repo.contents(of: "a.md", at: "HEAD")
        XCTAssertEqual(String(bytes: head, encoding: .utf8), "9")
        let after = try await repo.status()
        XCTAssertEqual(after, [], "the new commit's paths must not come back as a reverse staged change")
    }
}

extension Repository {
    /// Detaches HEAD at itself, for tests.
    func detach() throws {
        var oid = git_oid()
        try check(git_reference_name_to_id(&oid, handle, "HEAD"))
        try check(git_repository_set_head_detached(handle, &oid))
    }
}
