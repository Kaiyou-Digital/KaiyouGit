#if os(macOS)
    import Foundation
    @testable import KaiyouGit
    import XCTest

    /// `changedPaths(from:to:)` and `log(from:to:limit:)` against the real `git`, on fixtures with spaces, non-ASCII
    /// names and multi-line messages.
    final class HistoryParityTests: XCTestCase {
        private let author = Author(name: "Test", email: "test@example.invalid")

        func testChangedPathsBetweenCommitsMatchesGitDiff() async throws {
            let dir = try Fixtures.makeTempDir(for: self).appendingPathComponent("repo")
            let repo = try await Repository.initialize(at: dir, branch: "main")
            let names = [
                "archive/a.md", "archive-old/x.md", "My Notes/café 写真.md", "My Notes/keep.md", "my dir/ünï.md",
                "del ete.md", "old name.md", "plain.md",
            ]
            for name in names {
                try Fixtures.write("content of \(name), long enough to look like a rename", to: name, in: dir)
            }
            try await repo.stageAll()
            try await repo.commit(message: "seed", author: author)
            try Fixtures.write("2", to: "My Notes/café 写真.md", in: dir)
            try Fixtures.write("2", to: "archive/a.md", in: dir)
            try Fixtures.write("2", to: "archive-old/x.md", in: dir)
            try Fixtures.write("new", to: "My Notes/new 写真.md", in: dir)
            try FileManager.default.removeItem(at: dir.appendingPathComponent("del ete.md"))
            try FileManager.default.removeItem(at: dir.appendingPathComponent("my dir/ünï.md"))
            try FileManager.default.moveItem(
                at: dir.appendingPathComponent("old name.md"), to: dir.appendingPathComponent("new name.md")
            )
            try await repo.stageAll()
            try await repo.commit(message: "change", author: author)

            let specs: [[String]] = [[], ["My Notes"], ["archive"], ["./My Notes/"], ["."], ["my dir", "old name.md"]]
            for spec in specs {
                for (base, tip) in [("HEAD~1", "HEAD"), ("HEAD", "HEAD~1")] {
                    let expected = try Fixtures.gitLines(
                        ["diff", "--name-only", "--no-renames", base, tip, "--"] + spec,
                        in: dir
                    )
                    let actual = try await repo.changedPaths(from: base, to: tip, under: spec)
                    XCTAssertEqual(actual, expected.sorted(), "\(base) \(tip) \(spec)")
                }
            }
        }

        func testLogMatchesGitLog() async throws {
            let dir = try Fixtures.makeTempDir(for: self).appendingPathComponent("repo")
            let repo = try await Repository.initialize(at: dir, branch: "main")
            let messages = [
                "common", "ours 1\n\nbody of ours", "ours 2",
            ]
            let who = Author(name: "Zoë Müller 写真", email: "zoë@example.invalid")
            for (number, message) in messages.enumerated() {
                try Fixtures.write("\(number)", to: "f.md", in: dir)
                try await repo.stageAll()
                try await repo.commit(message: message, author: number == 1 ? who : author)
            }
            _ = try Fixtures.git(["branch", "ours"], in: dir)
            try await repo.resetHard(to: "HEAD~2")
            for message in [
                "theirs 1\nwrapped subject\n\nbody\nmore",
                "theirs 2",
                "ünï theirs 3\n",
                "theirs 4",
                "theirs 5",
            ] {
                try Fixtures.write(message, to: "g.md", in: dir)
                try await repo.stageAll()
                try await repo.commit(message: message, author: message.hasPrefix("ünï") ? who : author)
            }
            let ranges = [
                ("ours", "main"), ("main", "ours"), ("HEAD", "HEAD"), ("HEAD~5", "HEAD"), ("HEAD~2", "HEAD"),
                ("main", "HEAD~1"), ("HEAD~1", "main"), ("ours", "HEAD~3"),
            ]
            for (base, tip) in ranges {
                let format = "--format=%H%x00%s%x00%an%x00%ae%x00%ct"
                for limit in [nil, 0, 1, 2, 100] {
                    let limitArgs = limit.map { ["-n", String($0)] } ?? []
                    let expected = try Fixtures.gitLines(["log", format] + limitArgs + ["\(base)..\(tip)"], in: dir)
                    let actual = try await repo.log(from: base, to: tip, limit: limit).map {
                        [
                            $0.id.hex,
                            $0.subject,
                            $0.authorName,
                            $0.authorEmail,
                            String(Int($0.date.timeIntervalSince1970)),
                        ]
                        .joined(separator: "\u{0}")
                    }
                    XCTAssertEqual(actual, expected, "\(base)..\(tip) limit \(String(describing: limit))")
                }
            }
        }

        /// Author and committer differ: names and emails come from the author, the date from the committer.
        func testLogUsesAuthorIdentityAndCommitterTime() async throws {
            let dir = try Fixtures.makeTempDir(for: self).appendingPathComponent("repo")
            let repo = try await Repository.initialize(at: dir, branch: "main")
            for (number, split) in [false, true].enumerated() {
                try Fixtures.write("\(number)", to: "f.md", in: dir)
                _ = try Fixtures.git(["add", "f.md"], in: dir)
                _ = try Fixtures.git(["commit", "-m", "c\(number)"], in: dir, environment: [
                    "GIT_AUTHOR_NAME": "Ada Author", "GIT_AUTHOR_EMAIL": "ada@example.invalid",
                    "GIT_AUTHOR_DATE": "1700000000 +0000",
                    "GIT_COMMITTER_NAME": split ? "Carl Committer" : "Ada Author",
                    "GIT_COMMITTER_EMAIL": split ? "carl@example.invalid" : "ada@example.invalid",
                    "GIT_COMMITTER_DATE": split ? "1700005000 +0000" : "1700000000 +0000",
                ])
            }
            let expected = try Fixtures.gitLines(["log", "--format=%an%x00%ae%x00%ct", "HEAD~1..HEAD"], in: dir)
            XCTAssertEqual(expected, ["Ada Author\0ada@example.invalid\01700005000"])
            let commits = try await repo.log(from: "HEAD~1", to: "HEAD")
            let actual = commits.map {
                [$0.authorName, $0.authorEmail, String(Int($0.date.timeIntervalSince1970))].joined(separator: "\u{0}")
            }
            XCTAssertEqual(actual, expected)
        }
    }
#endif
