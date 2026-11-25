import CLibGit2
import Foundation
import KaiyouGit
import XCTest

/// Temp-directory helpers for tests.
enum Fixtures {
    /// A fresh directory under the system temp dir, removed when the test finishes.
    static func makeTempDir(for test: XCTestCase) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Writes `text` to `name` (which may contain subdirectories) inside `dir`.
    static func write(_ text: String, to name: String, in dir: URL) throws {
        try write(Data(text.utf8), to: name, in: dir)
    }

    /// Writes `count` random (so incompressible) bytes to `name` inside `dir`.
    static func writeRandom(count: Int, to name: String, in dir: URL) throws {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        try write(data, to: name, in: dir)
    }

    /// An empty bare repository whose HEAD names `main`, to push to; returns its directory.
    static func makeBareRepository(for test: XCTestCase) throws -> URL {
        LibGit2.initialize()
        let dir = try makeTempDir(for: test).appendingPathComponent("remote.git")
        var opts = git_repository_init_options()
        try check(git_repository_init_options_init(&opts, UInt32(GIT_REPOSITORY_INIT_OPTIONS_VERSION)))
        opts.flags = GIT_REPOSITORY_INIT_MKPATH.rawValue | GIT_REPOSITORY_INIT_BARE.rawValue
        var repo: OpaquePointer?
        try check("main".withCString { name in
            opts.initial_head = name
            return git_repository_init_ext(&repo, dir.path, &opts)
        })
        git_repository_free(repo)
        return dir
    }

    /// `git tag -f name rev` in the repository at `dir`, through a handle of its own.
    static func tag(_ name: String, at rev: String, in dir: URL) throws {
        var repo: OpaquePointer?
        try check(git_repository_open(&repo, dir.path))
        defer { git_repository_free(repo) }
        var target: OpaquePointer?
        try check(git_revparse_single(&target, repo, rev))
        defer { git_object_free(target) }
        var oid = git_oid()
        try check(git_tag_create_lightweight(&oid, repo, name, target, 1))
    }

    #if os(macOS)
        /// Runs the real `git` in `dir` with user config and quoting switched off, so only git's own behaviour is
        /// compared; returns its stdout and fails the test on a non-zero exit.
        static func git(_ args: [String], in dir: URL, environment: [String: String] = [:]) throws -> Data {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-c", "core.quotepath=off"] + args
            process.currentDirectoryURL = dir
            process.environment = [
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_CONFIG_SYSTEM": "/dev/null",
                "PATH": "/usr/bin",
            ].merging(environment) { _, new in new }
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "git \(args)")
            return out
        }

        /// `git(args, in:)` split into lines.
        static func gitLines(_ args: [String], in dir: URL) throws -> [String] {
            try (String(bytes: git(args, in: dir), encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
        }
    #endif

    private static func write(_ data: Data, to name: String, in dir: URL) throws {
        let file = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: file, options: .atomic)
    }

    private static func check(_ code: Int32) throws {
        if code < 0 { throw NSError(domain: "Fixtures", code: Int(code)) }
    }
}

/// Fails unless `body` throws exactly `expected`.
func assertThrows(
    _ expected: GitError,
    _ body: () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await body()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? GitError, expected, file: file, line: line)
    }
}

/// Fails unless `body` throws some `GitError`.
func assertThrowsGitError(
    _ body: () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await body()
        XCTFail("expected a GitError", file: file, line: line)
    } catch {
        XCTAssertTrue(error is GitError, "wrong error \(error)", file: file, line: line)
    }
}
