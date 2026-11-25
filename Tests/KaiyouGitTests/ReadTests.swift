import CLibGit2
import Foundation
@testable import KaiyouGit
import XCTest

final class ReadTests: XCTestCase {
    private let author = Author(name: "Test", email: "test@example.invalid")

    private func makeRepo(branch: String = "main") async throws -> (Repository, URL) {
        let dir = try Fixtures.makeTempDir(for: self).appendingPathComponent("repo")
        return try await (Repository.initialize(at: dir, branch: branch), dir)
    }

    @discardableResult
    private func commitFile(_ repo: Repository, _ dir: URL, _ name: String, _ text: String) async throws -> CommitID {
        try Fixtures.write(text, to: name, in: dir)
        try await repo.stageAll()
        return try await repo.commit(message: "edit \(name)", author: author)
    }

    /// Points `refs/remotes/origin/main` at `id`, as a fetch would.
    private func makeRemoteRef(_ repo: Repository, at id: CommitID) throws {
        var oid = git_oid()
        XCTAssertEqual(git_oid_fromstr(&oid, id.hex), 0)
        var ref: OpaquePointer?
        XCTAssertEqual(git_reference_create(&ref, repo.handle, "refs/remotes/origin/main", &oid, 1, nil), 0)
        git_reference_free(ref)
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

    func testResolveReturnsNilForMissingRef() async throws {
        let (repo, dir) = try await makeRepo()
        let first = try await commitFile(repo, dir, "a.md", "1")
        let second = try await commitFile(repo, dir, "a.md", "2")
        var resolved = try await repo.resolve("HEAD")
        XCTAssertEqual(resolved, second)
        resolved = try await repo.resolve("main")
        XCTAssertEqual(resolved, second)
        resolved = try await repo.resolve("HEAD~1")
        XCTAssertEqual(resolved, first)
        resolved = try await repo.resolve("nope")
        XCTAssertNil(resolved)
        resolved = try await repo.resolve("@{u}") // no upstream configured
        XCTAssertNil(resolved)
        resolved = try await repo.resolve("origin/main") // no such remote ref yet
        XCTAssertNil(resolved)
        try makeRemoteRef(repo, at: first)
        resolved = try await repo.resolve("origin/main")
        XCTAssertEqual(resolved, first)
    }

    func testResolveOnUnbornHeadIsNil() async throws {
        let (repo, _) = try await makeRepo()
        let head = try await repo.resolve("HEAD")
        XCTAssertNil(head)
    }

    func testContentsAtRevReturnsOldBytes() async throws {
        let (repo, dir) = try await makeRepo()
        try await commitFile(repo, dir, "config/key", "old")
        try await commitFile(repo, dir, "config/key", "new")
        let old = try await repo.contents(of: "config/key", at: "HEAD~1")
        XCTAssertEqual(old, Data("old".utf8))
        let current = try await repo.contents(of: "config/key", at: "HEAD")
        XCTAssertEqual(current, Data("new".utf8))
        await assertNotFound { try await repo.contents(of: "config/missing", at: "HEAD") }
        await assertNotFound { try await repo.contents(of: "config/key", at: "nope") }
    }

    func testListTreeNamesOnly() async throws {
        let (repo, dir) = try await makeRepo()
        try Fixtures.write("1", to: "config/a.json", in: dir)
        try Fixtures.write("2", to: "config/b.json", in: dir)
        try Fixtures.write("3", to: "config/sub/c.json", in: dir)
        try Fixtures.write("4", to: "other.md", in: dir)
        try await repo.stageAll()
        try await repo.commit(message: "x", author: author)
        let expected = ["config/a.json", "config/b.json", "config/sub"]
        let plain = try await repo.listTree(at: "HEAD", path: "config")
        XCTAssertEqual(plain, expected)
        let slashed = try await repo.listTree(at: "HEAD", path: "config/")
        XCTAssertEqual(slashed, expected)
        let missing = try await repo.listTree(at: "HEAD", path: "nothing")
        XCTAssertEqual(missing, [])
    }

    func testChangedPathsUnderPathspec() async throws {
        let (repo, dir) = try await makeRepo()
        try Fixtures.write("1", to: "archive/a.md", in: dir)
        try Fixtures.write("1", to: "other/b.md", in: dir)
        try await repo.stageAll()
        try await repo.commit(message: "x", author: author)
        try Fixtures.write("2", to: "archive/a.md", in: dir)
        try Fixtures.write("2", to: "other/b.md", in: dir)
        let scoped = try await repo.changedPaths(against: "HEAD", under: ["archive"])
        XCTAssertEqual(scoped, ["archive/a.md"])
        let unscoped = try await repo.changedPaths(against: "HEAD", under: [])
        XCTAssertEqual(unscoped, ["archive/a.md", "other/b.md"])
    }

    func testChangedPathsAcceptsDirectoryPathspec() async throws {
        let (repo, dir) = try await makeRepo()
        try Fixtures.write("1", to: "archive/deep/nested.md", in: dir)
        try Fixtures.write("1", to: "archive/mod.md", in: dir)
        try Fixtures.write("1", to: "archive/gone.md", in: dir)
        try Fixtures.write("1", to: "outside.md", in: dir)
        try await repo.stageAll()
        try await repo.commit(message: "x", author: author)
        try Fixtures.write("2", to: "archive/deep/nested.md", in: dir)
        try Fixtures.write("2", to: "archive/mod.md", in: dir)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("archive/gone.md"))
        try Fixtures.write("2", to: "outside.md", in: dir)
        try Fixtures.write("u", to: "archive/untracked.md", in: dir) // untracked: not reported
        let expected = ["archive/deep/nested.md", "archive/gone.md", "archive/mod.md"]
        let plain = try await repo.changedPaths(against: "HEAD", under: ["archive"])
        XCTAssertEqual(plain, expected)
        let slashed = try await repo.changedPaths(against: "HEAD", under: ["archive/"])
        XCTAssertEqual(slashed, expected)
        // staged changes count too, and each path appears once
        try await repo.stage(paths: ["archive/mod.md"])
        let staged = try await repo.changedPaths(against: "HEAD", under: ["archive", "archive/mod.md"])
        XCTAssertEqual(staged, expected)
    }

    func testAheadBehindCounts() async throws {
        let (repo, dir) = try await makeRepo()
        let base = try await commitFile(repo, dir, "a.md", "1")
        try makeRemoteRef(repo, at: base)
        try await commitFile(repo, dir, "a.md", "2")
        try await commitFile(repo, dir, "a.md", "3")
        let ahead = try await repo.aheadBehind(local: "main", upstream: "origin/main")
        XCTAssertEqual(ahead.ahead, 2)
        XCTAssertEqual(ahead.behind, 0)
        let behind = try await repo.aheadBehind(local: "origin/main", upstream: "main")
        XCTAssertEqual(behind.ahead, 0)
        XCTAssertEqual(behind.behind, 2)
        await assertNotFound { try await repo.aheadBehind(local: "main", upstream: "nope") }
    }

    func testUpstreamNilWithoutTracking() async throws {
        let (repo, dir) = try await makeRepo()
        let unborn = await repo.upstream
        XCTAssertNil(unborn)
        try await commitFile(repo, dir, "a.md", "1")
        let untracked = await repo.upstream
        XCTAssertNil(untracked)
    }

    func testUpstreamNamesTrackingRef() async throws {
        let (repo, dir) = try await makeRepo()
        let base = try await commitFile(repo, dir, "a.md", "1")
        try await repo.addRemote(name: "origin", url: "file:///nowhere")
        try await repo.setConfig("branch.main.remote", "origin")
        try await repo.setConfig("branch.main.merge", "refs/heads/main")
        let name = await repo.upstream
        XCTAssertEqual(name, "refs/remotes/origin/main")
        try makeRemoteRef(repo, at: base)
        let tracked = try await repo.resolve("@{u}")
        XCTAssertEqual(tracked, base)
    }

    func testConfigRoundTripAndMissingKeyIsNil() async throws {
        let (repo, _) = try await makeRepo()
        var value = try await repo.config("kaiyou.test")
        XCTAssertNil(value)
        try await repo.setConfig("kaiyou.test", "hello")
        value = try await repo.config("kaiyou.test")
        XCTAssertEqual(value, "hello")
        try await repo.setConfig("kaiyou.test", "again")
        value = try await repo.config("kaiyou.test")
        XCTAssertEqual(value, "again")
        let reopened = try await Repository.open(at: repo.path)
        value = try await reopened.config("kaiyou.test")
        XCTAssertEqual(value, "again") // persisted in the repository's own config file
    }

    func testSetRemoteURLReplaces() async throws {
        let (repo, _) = try await makeRepo()
        var url = try await repo.remoteURL(name: "origin")
        XCTAssertNil(url)
        try await repo.addRemote(name: "origin", url: "git@example.invalid:a/b.git")
        url = try await repo.remoteURL(name: "origin")
        XCTAssertEqual(url, "git@example.invalid:a/b.git")
        try await repo.setRemoteURL(name: "origin", url: "git@example.invalid:c/d.git")
        url = try await repo.remoteURL(name: "origin")
        XCTAssertEqual(url, "git@example.invalid:c/d.git")
        do {
            try await repo.addRemote(name: "origin", url: "x")
            XCTFail("expected an error for an existing remote")
        } catch is GitError {}
        await assertNotFound { try await repo.setRemoteURL(name: "missing", url: "x") }
    }

    func testCurrentBranchOnUnbornHeadAndNonDefaultInitialBranch() async throws {
        let (repo, _) = try await makeRepo()
        let main = await repo.currentBranch
        XCTAssertEqual(main, "main")
        let (trunk, _) = try await makeRepo(branch: "trunk")
        let name = await trunk.currentBranch
        XCTAssertEqual(name, "trunk")
    }

    func testHasCommitsFalseThenTrue() async throws {
        let (repo, dir) = try await makeRepo()
        let before = await repo.hasCommits
        XCTAssertFalse(before)
        try await commitFile(repo, dir, "a.md", "1")
        let after = await repo.hasCommits
        XCTAssertTrue(after)
        XCTAssertEqual(git_repository_set_head(repo.handle, "refs/heads/unborn"), 0) // HEAD unborn, main has one
        let otherRef = await repo.hasCommits
        XCTAssertTrue(otherRef)
    }

    /// As `git rev-list -n 1 --all`: refs that peel to no commit, or a HEAD that cannot be read, are not commits.
    func testHasCommitsFalseForTagOnlyRepoAndUnreadableHead() async throws {
        let (repo, dir) = try await makeRepo()
        var blobOid = git_oid()
        XCTAssertEqual(git_blob_create_from_buffer(&blobOid, repo.handle, "x", 1), 0)
        var blob: OpaquePointer?
        XCTAssertEqual(git_object_lookup(&blob, repo.handle, &blobOid, GIT_OBJECT_BLOB), 0)
        defer { git_object_free(blob) }
        var tagOid = git_oid()
        XCTAssertEqual(git_tag_create_lightweight(&tagOid, repo.handle, "blob-tag", blob, 0), 0)
        let tagOnly = await repo.hasCommits
        XCTAssertFalse(tagOnly)
        try Fixtures.write("not a ref", to: ".git/HEAD", in: dir)
        let unreadable = await repo.hasCommits
        XCTAssertFalse(unreadable)
    }

    func testCurrentBranchNilWhenDetached() async throws {
        let (repo, dir) = try await makeRepo()
        let first = try await commitFile(repo, dir, "a.md", "1")
        var oid = git_oid()
        XCTAssertEqual(git_oid_fromstr(&oid, first.hex), 0)
        XCTAssertEqual(git_repository_set_head_detached(repo.handle, &oid), 0)
        let detached = await repo.currentBranch
        XCTAssertNil(detached)
    }
}
