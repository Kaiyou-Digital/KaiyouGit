import Foundation
@testable import KaiyouGit
import XCTest

/// Folders as pathspecs, deletions included.
final class DirectoryPathspecTests: XCTestCase {
    private let author = Author(name: "Test", email: "test@example.invalid")

    private func makeRepo() async throws -> (Repository, URL) {
        let dir = try Fixtures.makeTempDir(for: self).appendingPathComponent("repo")
        return try await (Repository.initialize(at: dir), dir)
    }

    private func entry(_ path: String, _ index: Change?, _ workingTree: Change?) -> StatusEntry {
        StatusEntry(path: path, index: index, workingTree: workingTree)
    }

    /// Commits d/keep.md, d/sub/deep.md, d/gone.md and out.md.
    private func makeSeededRepo() async throws -> (Repository, URL) {
        let (repo, dir) = try await makeRepo()
        for name in ["d/keep.md", "d/sub/deep.md", "d/gone.md", "out.md"] {
            try Fixtures.write("1", to: name, in: dir)
        }
        try await repo.stageAll()
        try await repo.commit(message: "seed", author: author)
        return (repo, dir)
    }

    /// Modifies, deletes and adds files under d/ (unstaged).
    private func changeDirectory(_ dir: URL) throws {
        try Fixtures.write("2", to: "d/keep.md", in: dir)
        try Fixtures.write("2", to: "d/sub/deep.md", in: dir)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("d/gone.md"))
        try Fixtures.write("n", to: "d/sub/new.md", in: dir)
    }

    func testStatusDirectoryPathspec() async throws {
        let (repo, dir) = try await makeSeededRepo()
        try changeDirectory(dir)
        try Fixtures.write("2", to: "out.md", in: dir)
        let listed = try await repo.status(paths: ["d"])
        XCTAssertEqual(listed, [
            entry("d/gone.md", nil, .deleted),
            entry("d/keep.md", nil, .modified),
            entry("d/sub/deep.md", nil, .modified),
            entry("d/sub/new.md", nil, .untracked),
        ])
    }

    func testStageDirectoryPathspec() async throws {
        let (repo, dir) = try await makeSeededRepo()
        try changeDirectory(dir)
        try Fixtures.write("2", to: "out.md", in: dir)
        try await repo.stage(paths: ["d"])
        let after = try await repo.status()
        XCTAssertEqual(after, [
            entry("d/gone.md", .deleted, nil),
            entry("d/keep.md", .modified, nil),
            entry("d/sub/deep.md", .modified, nil),
            entry("d/sub/new.md", .added, nil),
            entry("out.md", nil, .modified),
        ])
    }

    func testUnstageDirectoryPathspecWithCommit() async throws {
        let (repo, dir) = try await makeSeededRepo()
        try changeDirectory(dir)
        try Fixtures.write("2", to: "out.md", in: dir)
        try await repo.stageAll()
        try await repo.unstage(paths: ["d"])
        let after = try await repo.status()
        XCTAssertEqual(after, [
            entry("d/gone.md", nil, .deleted),
            entry("d/keep.md", nil, .modified),
            entry("d/sub/deep.md", nil, .modified),
            entry("d/sub/new.md", nil, .untracked),
            entry("out.md", .modified, nil),
        ])
    }

    func testUnstageDirectoryPathspecWithUnbornHead() async throws {
        let (repo, dir) = try await makeRepo()
        try Fixtures.write("1", to: "d/a.md", in: dir)
        try Fixtures.write("1", to: "d/sub/b.md", in: dir)
        try Fixtures.write("1", to: "out.md", in: dir)
        try await repo.stageAll()
        try await repo.unstage(paths: ["d"])
        let after = try await repo.status()
        XCTAssertEqual(after, [
            entry("d/a.md", nil, .untracked),
            entry("d/sub/b.md", nil, .untracked),
            entry("out.md", .added, nil),
        ])
    }

    /// `.` is the whole tree, as git reads it at the top of the working tree, not only the paths starting with ".".
    func testDotPathspecIsTheWholeTree() async throws {
        let (repo, dir) = try await makeSeededRepo()
        try changeDirectory(dir)
        try Fixtures.write("2", to: "out.md", in: dir)
        try Fixtures.write("1", to: ".hidden", in: dir)
        let everything = try await repo.status()
        let dot = try await repo.status(paths: ["."])
        XCTAssertEqual(dot, everything)
        let changed = try await repo.changedPaths(against: "HEAD", under: ["."])
        XCTAssertEqual(changed, ["d/gone.md", "d/keep.md", "d/sub/deep.md", "out.md"])
        try await repo.stageAll()
        try await repo.unstage(paths: ["."])
        let after = try await repo.status()
        XCTAssertEqual(after, everything)
    }

    func testCommitDirectoryPathspecIncludesDeletionsAndLeavesOutsideStaged() async throws {
        let (repo, dir) = try await makeSeededRepo()
        try changeDirectory(dir)
        try Fixtures.write("2", to: "out.md", in: dir)
        try await repo.stage(paths: ["out.md"])
        try await repo.commit(message: "dir", author: author, paths: ["d"])
        let after = try await repo.status()
        XCTAssertEqual(after, [entry("out.md", .modified, nil)])
    }

    func testCommitDirectoryAndFilePathspecs() async throws {
        let (repo, dir) = try await makeSeededRepo()
        try changeDirectory(dir)
        try Fixtures.write("2", to: "out.md", in: dir)
        try await repo.commit(message: "both", author: author, paths: ["d", "out.md"])
        let after = try await repo.status()
        XCTAssertEqual(after, [])
    }

    func testCommitEmptyPathsThrowsAndTouchesNothing() async throws {
        let (repo, dir) = try await makeSeededRepo()
        try Fixtures.write("2", to: "out.md", in: dir)
        do {
            try await repo.commit(message: "none", author: author, paths: [])
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? GitError, .nothingToCommit)
        }
        let after = try await repo.status()
        XCTAssertEqual(after, [entry("out.md", nil, .modified)])
    }

    func testCheckoutDirectoryPathspec() async throws {
        let (repo, dir) = try await makeSeededRepo()
        try changeDirectory(dir)
        try await repo.checkout(paths: ["d"])
        let after = try await repo.status()
        XCTAssertEqual(after, [entry("d/sub/new.md", nil, .untracked)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("d/gone.md").path))
    }

    func testCheckoutPathAbsentFromRevThrowsNotFoundAndKeepsFile() async throws {
        let (repo, dir) = try await makeRepo()
        try Fixtures.write("1", to: "a.md", in: dir)
        try await repo.stageAll()
        let first = try await repo.commit(message: "first", author: author)
        try Fixtures.write("1", to: "b.md", in: dir)
        try await repo.stageAll()
        try await repo.commit(message: "second", author: author)
        do {
            try await repo.checkout(paths: ["b.md"], from: first.hex)
            XCTFail("expected an error")
        } catch {
            guard case .notFound = error as? GitError else { return XCTFail("got \(error)") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("b.md").path))
        let after = try await repo.status()
        XCTAssertEqual(after, [])
    }
}
