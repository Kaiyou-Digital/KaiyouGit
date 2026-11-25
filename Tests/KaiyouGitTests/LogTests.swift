import CLibGit2
import Foundation
@testable import KaiyouGit
import XCTest

final class LogTests: XCTestCase {
    private let author = Author(name: "Test", email: "test@example.invalid")

    private func makeRepo() async throws -> (Repository, URL) {
        let dir = try Fixtures.makeTempDir(for: self).appendingPathComponent("repo")
        return try await (Repository.initialize(at: dir, branch: "main"), dir)
    }

    @discardableResult
    private func commitFile(
        _ repo: Repository, _ dir: URL, _ name: String, message: String, as who: Author? = nil
    ) async throws -> CommitID {
        try Fixtures.write(message, to: name, in: dir)
        try await repo.stageAll()
        return try await repo.commit(message: message, author: who ?? author)
    }

    /// Creates `refs/heads/<name>` (or another full ref) at `id`.
    private func makeRef(_ repo: Repository, _ name: String, at id: CommitID) throws {
        var oid = git_oid()
        XCTAssertEqual(git_oid_fromstr(&oid, id.hex), 0)
        var ref: OpaquePointer?
        XCTAssertEqual(git_reference_create(&ref, repo.handle, name, &oid, 1, nil), 0)
        git_reference_free(ref)
    }

    /// A root commit, then c1, c2, c3 on main; the returned ids are c1 to c3.
    private func makeLine() async throws -> (Repository, [CommitID]) {
        let (repo, dir) = try await makeRepo()
        try await commitFile(repo, dir, "f.md", message: "root")
        var ids: [CommitID] = []
        for number in 1 ... 3 {
            try await ids.append(commitFile(repo, dir, "f.md", message: "c\(number)"))
        }
        return (repo, ids)
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

    /// A blob asked for as a commit or tree is `.other` with libgit2's GIT_EINVALIDSPEC "cannot be peeled" error, not
    /// `.notFound`.
    private func assertCannotPeel(
        _ body: () async throws -> some Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await body()
            XCTFail("expected a peel error", file: file, line: line)
        } catch let GitError.other(_, code, _) {
            XCTAssertEqual(code, GIT_EINVALIDSPEC.rawValue, file: file, line: line)
        } catch {
            XCTFail("wrong error \(error)", file: file, line: line)
        }
    }

    func testLogRangeListsCommitsNewestFirst() async throws {
        let (repo, ids) = try await makeLine()
        let list = try await repo.log(from: "HEAD~3", to: "HEAD").map(\.id)
        XCTAssertEqual(list, [ids[2], ids[1], ids[0]])
    }

    func testLogRangeExcludesBaseAncestors() async throws {
        let (repo, ids) = try await makeLine()
        let list = try await repo.log(from: "HEAD~1", to: "HEAD")
        XCTAssertEqual(list.map(\.id), [ids[2]])
        XCTAssertEqual(list.first?.subject, "c3")
        XCTAssertEqual(list.first?.authorName, "Test")
        XCTAssertEqual(list.first?.authorEmail, "test@example.invalid")
        XCTAssertLessThan(abs(list[0].date.timeIntervalSinceNow), 60)
    }

    func testLogDivergedRangeIsTipOnly() async throws {
        let (repo, dir) = try await makeRepo()
        try await commitFile(repo, dir, "f.md", message: "common")
        let oursTip = try await commitFile(repo, dir, "f.md", message: "ours")
        try makeRef(repo, "refs/heads/ours", at: oursTip)
        try await repo.resetHard(to: "HEAD~1")
        let theirsFirst = try await commitFile(repo, dir, "g.md", message: "theirs 1")
        let theirsLast = try await commitFile(repo, dir, "g.md", message: "theirs 2")
        let list = try await repo.log(from: "ours", to: "main").map(\.id)
        XCTAssertEqual(list, [theirsLast, theirsFirst])
        let reverse = try await repo.log(from: "main", to: "ours").map(\.id)
        XCTAssertEqual(reverse, [oursTip])
    }

    func testLogEmptyRangeIsEmpty() async throws {
        let (repo, _) = try await makeLine()
        let same = try await repo.log(from: "HEAD", to: "HEAD")
        XCTAssertEqual(same, [])
        let reversed = try await repo.log(from: "HEAD", to: "HEAD~2")
        XCTAssertEqual(reversed, [])
    }

    func testLogLimitZeroOneAndLargerThanRange() async throws {
        let (repo, ids) = try await makeLine()
        let zero = try await repo.log(from: "HEAD~3", to: "HEAD", limit: 0)
        XCTAssertEqual(zero, [])
        let one = try await repo.log(from: "HEAD~3", to: "HEAD", limit: 1).map(\.id)
        XCTAssertEqual(one, [ids[2]])
        let large = try await repo.log(from: "HEAD~3", to: "HEAD", limit: 10).map(\.id)
        XCTAssertEqual(large, ids.reversed())
        await assertThrowsGitError { try await repo.log(from: "HEAD~3", to: "HEAD", limit: -1) }
    }

    func testLogSubjectIsFirstLineOfMultiLineMessage() async throws {
        let (repo, dir) = try await makeRepo()
        try await commitFile(repo, dir, "f.md", message: "base")
        try await commitFile(repo, dir, "f.md", message: "Subject line\n\nBody text\nmore body")
        // git_commit_summary (like `git log %s`) joins a wrapped first paragraph with spaces.
        try await commitFile(repo, dir, "f.md", message: "Wrapped\nsubject\n\nbody")
        let subjects = try await repo.log(from: "HEAD~2", to: "HEAD").map(\.subject)
        XCTAssertEqual(subjects, ["Wrapped subject", "Subject line"])
    }

    func testLogNonASCIIAuthorName() async throws {
        let (repo, dir) = try await makeRepo()
        try await commitFile(repo, dir, "f.md", message: "base")
        let who = Author(name: "Zoë Müller 写真", email: "zoë@example.invalid")
        try await commitFile(repo, dir, "f.md", message: "ünï", as: who)
        let list = try await repo.log(from: "HEAD~1", to: "HEAD")
        XCTAssertEqual(list.first?.authorName, "Zoë Müller 写真")
        XCTAssertEqual(list.first?.authorEmail, "zoë@example.invalid")
        XCTAssertEqual(list.first?.subject, "ünï")
    }

    /// A walk that fails part way (a missing commit object) throws; it must not return the commits before the gap.
    func testLogThrowsWhenTheWalkHitsAMissingObject() async throws {
        let (repo, ids) = try await makeLine()
        let dir = await repo.path
        let resolved = try await repo.resolve("HEAD~3")
        let root = try XCTUnwrap(resolved).hex // named by hash, so no walk is needed to find it
        let hex = ids[0].hex // c1, between HEAD and the root
        let object = dir.appendingPathComponent(".git/objects/\(hex.prefix(2))/\(hex.dropFirst(2))")
        XCTAssertTrue(FileManager.default.fileExists(atPath: object.path))
        try FileManager.default.removeItem(at: object)
        let reopened = try await Repository.open(at: dir)
        await assertThrowsGitError { try await reopened.log(from: root, to: "HEAD") }
    }

    func testLogUnknownRevIsNotFound() async throws {
        let (repo, _) = try await makeLine()
        await assertNotFound { try await repo.log(from: "nope", to: "HEAD") }
        await assertNotFound { try await repo.log(from: "HEAD", to: "nope") }
    }

    func testLogUpstreamSpelling() async throws {
        let (repo, dir) = try await makeRepo()
        let base = try await commitFile(repo, dir, "f.md", message: "base")
        try makeRef(repo, "refs/remotes/origin/main", at: base)
        try await repo.addRemote(name: "origin", url: "/nowhere")
        try await repo.setConfig("branch.main.remote", "origin")
        try await repo.setConfig("branch.main.merge", "refs/heads/main")
        let next = try await commitFile(repo, dir, "f.md", message: "next")
        let incoming = try await repo.log(from: "HEAD", to: "@{u}")
        XCTAssertEqual(incoming, [])
        let outgoing = try await repo.log(from: "@{u}", to: "HEAD", limit: 10).map(\.id)
        XCTAssertEqual(outgoing, [next])
    }

    /// A blob is neither a commit nor a tree, and an annotated tag peels to a commit.
    func testRevsThatAreNotCommitsOrTrees() async throws {
        let (repo, ids) = try await makeLine()
        let blob = "HEAD:f.md"
        await assertCannotPeel { try await repo.log(from: "HEAD~1", to: blob) }
        await assertCannotPeel { try await repo.changedPaths(from: "HEAD~1", to: blob) }
        await assertCannotPeel { try await repo.changedPaths(against: blob, under: []) }
        // An annotated tag object peels to the commit (and its tree), so it works wherever a commit does.
        var tagOid = git_oid()
        var target: OpaquePointer?
        XCTAssertEqual(git_revparse_single(&target, repo.handle, "HEAD~1"), 0)
        var signature: UnsafeMutablePointer<git_signature>?
        XCTAssertEqual(git_signature_now(&signature, "T", "t@example.invalid"), 0)
        XCTAssertEqual(git_tag_create(&tagOid, repo.handle, "v1", target, signature, "annotated", 0), 0)
        git_signature_free(signature)
        git_object_free(target)
        let list = try await repo.log(from: "v1", to: "HEAD").map(\.id)
        XCTAssertEqual(list, [ids[2]])
        let names = try await repo.changedPaths(from: "v1", to: "HEAD")
        XCTAssertEqual(names, ["f.md"])
    }
}
