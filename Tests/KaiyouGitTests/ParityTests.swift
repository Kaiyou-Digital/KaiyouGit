#if os(macOS)
    import Foundation
    @testable import KaiyouGit
    import XCTest

    /// The library against the real `git` CLI on one fixture, with user config and quoting switched off so only
    /// git's own behaviour is compared.
    final class ParityTests: XCTestCase {
        private let author = Author(name: "Test", email: "test@example.invalid")
        private let reverted = "reverted.md"
        private let revertedSameSize = "reverted-same.md"
        private let restaged = "restaged.md"

        private func lines(_ data: Data) -> [String] {
            (String(bytes: data, encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
        }

        /// HEAD holds every file below; then the working tree and index are changed in each way git distinguishes.
        private func makeFixture() async throws -> (Repository, URL) {
            let dir = try Fixtures.makeTempDir(for: self).appendingPathComponent("repo")
            let repo = try await Repository.initialize(at: dir)
            let names = [
                "archive/a.md", "archive/sub/b.md", "archive-old/x.md", "My Notes/café 写真.md", "My Notes/keep.md",
                "mod.md", "del.md", restaged, "my dir/ünï.md", reverted, revertedSameSize,
            ]
            for name in names {
                try Fixtures.write("1", to: name, in: dir)
            }
            try await repo.stageAll()
            try await repo.commit(message: "seed", author: author)

            try Fixtures.write("2", to: "archive/a.md", in: dir) // staged modify
            try await repo.stage(paths: ["archive/a.md"])
            try Fixtures.write("2", to: "archive/sub/b.md", in: dir) // staged, then modified again
            try await repo.stage(paths: ["archive/sub/b.md"])
            try Fixtures.write("3", to: "archive/sub/b.md", in: dir)
            try Fixtures.write("2", to: "archive-old/x.md", in: dir) // sibling prefix of archive
            try Fixtures.write("2", to: "My Notes/café 写真.md", in: dir)
            try Fixtures.write("2", to: "my dir/ünï.md", in: dir)
            try Fixtures.write("2", to: "mod.md", in: dir)
            try FileManager.default.removeItem(at: dir.appendingPathComponent("del.md"))
            // Staged with other content, then the working tree put back as HEAD has it: with a size the index does not
            // record (libgit2 never hashes the file) and with the same size (it does).
            try Fixtures.write("staged-longer", to: reverted, in: dir)
            try Fixtures.write("9", to: revertedSameSize, in: dir)
            try await repo.stage(paths: [reverted, revertedSameSize])
            try Fixtures.write("1", to: reverted, in: dir)
            try Fixtures.write("1", to: revertedSameSize, in: dir)
            try Fixtures.write("staged-other", to: restaged, in: dir) // staged, then staged again as HEAD had it
            try await repo.stage(paths: [restaged])
            try Fixtures.write("1", to: restaged, in: dir)
            try await repo.stage(paths: [restaged])
            try Fixtures.write("n", to: "staged new.md", in: dir) // staged add
            try await repo.stage(paths: ["staged new.md"])
            try Fixtures.write("n", to: "My Notes/new 写真.md", in: dir) // untracked
            try Fixtures.write("n", to: "deep/er/untracked.md", in: dir)
            return (repo, dir)
        }

        private func change(_ code: Character) -> Change? {
            switch code {
            case "A": .added
            case "M": .modified
            case "D": .deleted
            default: nil
            }
        }

        func testStatusMatchesGitCLI() async throws {
            let (repo, dir) = try await makeFixture()
            let raw = try Fixtures.git(["status", "--porcelain=v1", "-z", "--no-renames", "-uall"], in: dir)
            let expected = (String(bytes: raw, encoding: .utf8) ?? "").split(separator: "\0")
                .map { record -> StatusEntry in
                    let code = Array(record.prefix(2))
                    let path = String(record.dropFirst(3))
                    if code == ["?", "?"] { return StatusEntry(path: path, index: nil, workingTree: .untracked) }
                    return StatusEntry(path: path, index: change(code[0]), workingTree: change(code[1]))
                }
            XCTAssertEqual(expected.count, 12)
            let actual = try await repo.status()
            XCTAssertEqual(actual.sorted { $0.path < $1.path }, expected.sorted { $0.path < $1.path })
            let dot = try await repo.status(paths: ["."])
            XCTAssertEqual(dot.sorted { $0.path < $1.path }, expected.sorted { $0.path < $1.path })
        }

        func testChangedPathsMatchesGitDiff() async throws {
            let (repo, dir) = try await makeFixture()
            let cases: [[String]] = [
                [], ["."], ["archive"], ["archive/"], ["archive-old"], ["My Notes"], ["my dir"], [
                    "archive",
                    "My Notes",
                ],
                ["mod.md", "del.md"], [restaged], ["My Notes/café 写真.md"], [reverted], [revertedSameSize], ["re*"],
                [".", "archive"],
            ]
            for paths in cases {
                let cli = try lines(Fixtures.git(["diff", "--name-only", "HEAD", "--"] + paths, in: dir)).sorted()
                let actual = try await repo.changedPaths(against: "HEAD", under: paths)
                XCTAssertEqual(actual, cli, "paths \(paths)")
            }
            let archive = try await repo.changedPaths(against: "HEAD", under: ["archive"])
            XCTAssertEqual(archive, ["archive/a.md", "archive/sub/b.md"]) // archive-old/x.md is a sibling, not under it
            let none = try await repo.changedPaths(against: "HEAD", under: [restaged, reverted, revertedSameSize])
            XCTAssertEqual(none, []) // staged with other content, then the index or the working tree put back
            let unicode = try await repo.changedPaths(against: "HEAD", under: ["My Notes"])
            XCTAssertEqual(unicode, ["My Notes/café 写真.md"])
            let all = try await repo.changedPaths(against: "HEAD", under: [])
            let dot = try await repo.changedPaths(against: "HEAD", under: ["."])
            XCTAssertEqual(dot, all)
            XCTAssertEqual(all.count, 8)
        }

        func testContentsMatchesGitShow() async throws {
            let (repo, dir) = try await makeFixture()
            for path in ["My Notes/café 写真.md", "archive/a.md", "my dir/ünï.md", "del.md"] {
                let cli = try Fixtures.git(["show", "HEAD:\(path)"], in: dir)
                let actual = try await repo.contents(of: path, at: "HEAD")
                XCTAssertEqual(actual, cli, path)
            }
        }

        func testListTreeMatchesLsTree() async throws {
            let (repo, dir) = try await makeFixture()
            let directories = ["", "archive", "archive/", "My Notes", "my dir", "archive/sub"]
            let notDirectories = ["mod.md", "archive/a.md", "nowhere"] // git prints nothing; the library returns []
            for path in directories + notDirectories {
                let spec = path.isEmpty ? [] : [path.hasSuffix("/") ? path : path + "/"]
                let cli = try lines(Fixtures.git(["ls-tree", "--name-only", "HEAD"] + spec, in: dir))
                let actual = try await repo.listTree(at: "HEAD", path: path)
                XCTAssertEqual(actual.sorted(), cli.sorted(), "path \(path)")
                if notDirectories.contains(path) { XCTAssertEqual(actual, [], "path \(path)") }
            }
        }

        func testStageAndCheckoutKeepWhatGitKeeps() async throws {
            let (repo, dir) = try await makeFixture()
            try await repo.unstage(paths: ["."])
            try Fixtures.write("x", to: "x.md", in: dir)
            try Fixtures.write("y", to: "y.md", in: dir)
            try Fixtures.write("n", to: "archive/new.md", in: dir)
            _ = try Fixtures.git(["add", "x.md", "archive/new.md"], in: dir) // staged behind the library's cached index
            try await repo.stage(paths: ["y.md"])
            let staged = try lines(Fixtures.git(["diff", "--cached", "--name-only"], in: dir))
            XCTAssertTrue(staged.contains("x.md") && staged.contains("y.md"), "\(staged)")
            try await repo.checkout(paths: ["archive"])
            _ = try Fixtures.git(["checkout", "HEAD", "--", "archive-old"], in: dir) // git keeps staged-new files too
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("archive/new.md").path))
            let after = try lines(Fixtures.git(["diff", "--cached", "--name-only"], in: dir))
            XCTAssertTrue(after.contains("archive/new.md"), "\(after)")
        }
    }
#endif
