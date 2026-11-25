import CLibGit2
import Foundation
@testable import KaiyouGit
import os
import XCTest

/// Clone, fetch, push and fast-forward against `file://` remotes built here; nothing touches the network.
final class RemoteTests: XCTestCase {
    private let author = Author(name: "Test", email: "test@example.invalid")

    /// A working repository with `a.md` committed, to clone from, and its directory (cloned as a `file://` URL).
    /// The path has a space and a non-ASCII letter, as real folder names often do.
    private func makeUpstream() async throws -> (Repository, URL) {
        let dir = try Fixtures.makeTempDir(for: self).appendingPathComponent("up stream ü")
        let repo = try await Repository.initialize(at: dir)
        try await commitFile(repo, "a.md", "one")
        return (repo, dir)
    }

    @discardableResult
    private func commitFile(_ repo: Repository, _ name: String, _ text: String) async throws -> CommitID {
        try await Fixtures.write(text, to: name, in: repo.path)
        try await repo.stageAll()
        return try await repo.commit(message: "edit \(name)", author: author)
    }

    /// Clones the repository at `source` through its `file://` URL.
    private func clone(_ source: URL) async throws -> (Repository, URL) {
        let dir = try Fixtures.makeTempDir(for: self).appendingPathComponent("My Notes/clone")
        return try await (Repository.clone(from: source.absoluteString, to: dir), dir)
    }

    /// A repository with one commit whose `origin` is a fresh bare repository it has pushed `main` to.
    private func makePushedRepo() async throws -> (Repository, remote: URL) {
        let remote = try Fixtures.makeBareRepository(for: self)
        let dir = try Fixtures.makeTempDir(for: self).appendingPathComponent("local")
        let repo = try await Repository.initialize(at: dir)
        try await commitFile(repo, "a.md", "one")
        try await repo.addRemote(name: "origin", url: remote.absoluteString)
        try await repo.push(refspec: "HEAD:refs/heads/main")
        return (repo, remote)
    }

    private func read(_ name: String, in dir: URL) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    func testCloneFetchFastForward() async throws {
        let (upstream, upstreamDir) = try await makeUpstream()
        let (repo, dir) = try await clone(upstreamDir)
        let first = try await upstream.resolve("HEAD")
        var head = try await repo.resolve("HEAD")
        XCTAssertEqual(head, first)
        XCTAssertEqual(try read("a.md", in: dir), "one")
        let tracking = await repo.upstream
        XCTAssertEqual(tracking, "refs/remotes/origin/main")

        let second = try await commitFile(upstream, "a.md", "two")
        try await repo.fetch()
        let fetched = try await repo.resolve("origin/main")
        XCTAssertEqual(fetched, second)
        try await repo.fastForward(to: "origin/main")
        head = try await repo.resolve("HEAD")
        XCTAssertEqual(head, second)
        let committed = try await repo.contents(of: "a.md", at: "HEAD")
        XCTAssertEqual(committed, Data("two".utf8))
        XCTAssertEqual(try read("a.md", in: dir), "two")
        let status = try await repo.status()
        XCTAssertEqual(status, [])
    }

    func testFetchUpdatesRemoteTrackingRefsAndTags() async throws {
        let (upstream, upstreamDir) = try await makeUpstream()
        let first = try await upstream.resolve("HEAD")
        try Fixtures.tag("v1", at: "HEAD", in: upstreamDir)
        try await commitFile(upstream, "a.md", "two")
        let (repo, _) = try await clone(upstreamDir)
        let clonedTag = try await repo.resolve("refs/tags/v1")
        XCTAssertEqual(clonedTag, first)

        // The upstream rewrites main (not a fast-forward of what was fetched), moves v1 and adds v2.
        try await upstream.resetHard(to: "HEAD~1")
        let rewritten = try await commitFile(upstream, "b.md", "other")
        try Fixtures.tag("v1", at: "HEAD", in: upstreamDir)
        try Fixtures.tag("v2", at: "HEAD", in: upstreamDir)
        try await repo.fetch()
        for name in ["origin/main", "refs/tags/v1", "refs/tags/v2"] {
            let id = try await repo.resolve(name)
            XCTAssertEqual(id, rewritten, name)
        }
    }

    func testFastForwardNoOpWhenAlreadyUpToDate() async throws {
        let (_, upstreamDir) = try await makeUpstream()
        let (repo, dir) = try await clone(upstreamDir)
        let start = try await repo.resolve("HEAD")
        try await repo.fastForward(to: "origin/main")
        var head = try await repo.resolve("HEAD")
        XCTAssertEqual(head, start)

        let ahead = try await commitFile(repo, "a.md", "local")
        try await repo.fastForward(to: "origin/main")
        head = try await repo.resolve("HEAD")
        XCTAssertEqual(head, ahead)
        XCTAssertEqual(try read("a.md", in: dir), "local")
    }

    func testFastForwardOntoUnbornBranch() async throws {
        let (upstream, upstreamDir) = try await makeUpstream()
        let dir = try Fixtures.makeTempDir(for: self).appendingPathComponent("fresh")
        let repo = try await Repository.initialize(at: dir)
        try await repo.addRemote(name: "origin", url: upstreamDir.absoluteString)
        try await repo.fetch()
        try await repo.fastForward(to: "origin/main")
        let head = try await repo.resolve("HEAD")
        let expected = try await upstream.resolve("HEAD")
        XCTAssertEqual(head, expected)
        XCTAssertEqual(try read("a.md", in: dir), "one")
    }

    func testFastForwardDivergedThrowsNotFastForward() async throws {
        let (upstream, upstreamDir) = try await makeUpstream()
        let (repo, dir) = try await clone(upstreamDir)
        let local = try await commitFile(repo, "b.md", "local")
        try await commitFile(upstream, "c.md", "remote")
        try await repo.fetch()
        await assertThrows(.notFastForward) { try await repo.fastForward(to: "origin/main") }
        let head = try await repo.resolve("HEAD")
        XCTAssertEqual(head, local)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("c.md").path))
    }

    /// Review Focus 3.
    func testFastForwardRefusesWhenDirtyFileOverlaps() async throws {
        let (upstream, upstreamDir) = try await makeUpstream()
        let (repo, dir) = try await clone(upstreamDir)
        try Fixtures.write("new", to: "n.md", in: upstreamDir)
        try await commitFile(upstream, "a.md", "remote edit")
        try await repo.fetch()
        let before = try await repo.resolve("HEAD")
        try Fixtures.write("local edit", to: "a.md", in: dir)

        await assertThrows(.wouldOverwriteLocalChanges) { try await repo.fastForward(to: "origin/main") }
        XCTAssertEqual(try read("a.md", in: dir), "local edit")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("n.md").path))
        let head = try await repo.resolve("HEAD")
        XCTAssertEqual(head, before)
        let main = try await repo.resolve("refs/heads/main")
        XCTAssertEqual(main, before)
        let branch = await repo.currentBranch
        XCTAssertEqual(branch, "main")
    }

    /// A branch that cannot move after the checkout (here a stale lock file) puts the working tree and index back.
    func testFastForwardRollsBackWhenTheBranchCannotMove() async throws {
        let (upstream, upstreamDir) = try await makeUpstream()
        let (repo, dir) = try await clone(upstreamDir)
        try Fixtures.write("new", to: "n.md", in: upstreamDir)
        try await commitFile(upstream, "a.md", "remote edit")
        try await repo.fetch()
        try Fixtures.write("local", to: "untracked.md", in: dir)
        let head = try await repo.resolve("HEAD")
        let status = try await repo.status()
        try Fixtures.write("", to: ".git/refs/heads/main.lock", in: dir)

        do {
            try await repo.fastForward(to: "origin/main")
            XCTFail("expected the locked branch to throw")
        } catch let GitError.other(_, code, _) {
            XCTAssertEqual(code, GIT_ELOCKED.rawValue)
        }
        XCTAssertEqual(try read("a.md", in: dir), "one")
        XCTAssertEqual(try read("untracked.md", in: dir), "local")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("n.md").path))
        let after = try await repo.status()
        XCTAssertEqual(after, status)
        let headAfter = try await repo.resolve("HEAD")
        XCTAssertEqual(headAfter, head)
    }

    func testPushToBareRemote() async throws {
        let (repo, remote) = try await makePushedRepo()
        let head = try await repo.resolve("HEAD")
        let pushed = try await Repository.open(at: remote).resolve("main")
        XCTAssertEqual(pushed, head)
        let tracking = try await repo.resolve("origin/main")
        XCTAssertEqual(tracking, head)
        let (copy, copyDir) = try await clone(remote)
        let copied = try await copy.resolve("HEAD")
        XCTAssertEqual(copied, head)
        XCTAssertEqual(try read("a.md", in: copyDir), "one")
    }

    /// Review Focus 4.
    func testPushNonFastForwardIsTyped() async throws {
        let (repo, remote) = try await makePushedRepo()
        let (other, _) = try await clone(remote)
        let theirs = try await commitFile(other, "b.md", "theirs")
        try await other.push(refspec: "HEAD:refs/heads/main")
        try await commitFile(repo, "c.md", "ours")

        await assertThrows(.notFastForward) { try await repo.push(refspec: "HEAD:refs/heads/main") }
        let remoteMain = try await Repository.open(at: remote).resolve("main")
        XCTAssertEqual(remoteMain, theirs)
    }

    /// A remote that cannot update the ref (here a stale lock file) refuses it only through the push-update-reference
    /// status, as a server reports a non-fast-forward it refuses itself; without that callback the push "succeeds".
    func testPushRefusedByRemoteThrows() async throws {
        let (repo, remote) = try await makePushedRepo()
        let before = try await Repository.open(at: remote).resolve("main")
        try await commitFile(repo, "b.md", "two")
        try Fixtures.write("", to: "refs/heads/main.lock", in: remote)
        do {
            try await repo.push(refspec: "HEAD:refs/heads/main")
            XCTFail("expected the refusal to throw")
        } catch let GitError.other(_, _, message) {
            XCTAssertTrue(message.hasPrefix("the remote refused refs/heads/main: "), message)
        }
        let after = try await Repository.open(at: remote).resolve("main")
        XCTAssertEqual(after, before)
        XCTAssertEqual(
            RemoteContext.pushRejection(ref: "refs/heads/main", status: "non-fast-forward"), .notFastForward
        )
        XCTAssertEqual(RemoteContext.pushRejection(ref: "refs/heads/main", status: "fetch first"), .notFastForward)
    }

    func testCancelledCloneThrowsCancelled() async throws {
        let (upstream, upstreamDir) = try await makeUpstream()
        for index in 0 ..< 200 {
            try Fixtures.writeRandom(count: 100_000, to: "big/\(index).bin", in: upstreamDir)
        }
        try await upstream.stageAll()
        try await upstream.commit(message: "big", author: author)
        let dest = try Fixtures.makeTempDir(for: self).appendingPathComponent("clone")
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let task = Task {
            try await Repository.clone(from: upstreamDir.absoluteString, to: dest) { _ in
                calls.withLock { $0 += 1 }
                withUnsafeCurrentTask { $0?.cancel() } // progress runs on the clone's own task
            }
        }
        await assertThrows(.cancelled) { try await task.value }
        XCTAssertEqual(calls.withLock { $0 }, 1, "the transfer stops at the tick it was cancelled on")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    /// Review Focus 5.
    func testCloneIntoExistingNonEmptyDirectoryThrowsAndKeepsFiles() async throws {
        let (_, upstreamDir) = try await makeUpstream()
        let dest = try Fixtures.makeTempDir(for: self)
        try Fixtures.write("keep", to: "sentinel.txt", in: dest)
        await assertThrows(.destinationNotEmpty(dest)) { try await Repository.clone(
            from: upstreamDir.absoluteString,
            to: dest
        ) }
        XCTAssertEqual(try read("sentinel.txt", in: dest), "keep")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dest.path), ["sentinel.txt"])
    }

    func testFailedCloneRemovesWhatItCreated() async throws {
        let parent = try Fixtures.makeTempDir(for: self) // exists and is empty
        let badSource = parent.appendingPathComponent("missing.git").absoluteString
        let dest = parent.appendingPathComponent("a/b/clone")
        await assertThrowsGitError { try await Repository.clone(from: badSource, to: dest) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: parent.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])

        // An existing empty destination is kept, and emptied of what the clone put there.
        let empty = parent.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        await assertThrowsGitError { try await Repository.clone(from: badSource, to: empty) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: empty.path), [])
    }

    /// `..` after a symlinked directory: the check, the walk and the clone use one spelling of the path, so a
    /// directory that was already there is never taken for one the clone made.
    func testFailedCloneThroughSymlinkAndDotDotKeepsWhatWasThere() async throws {
        let parent = try Fixtures.makeTempDir(for: self)
        let files = FileManager.default
        try files.createDirectory(at: parent.appendingPathComponent("real/inner"), withIntermediateDirectories: true)
        try files.createSymbolicLink(
            at: parent.appendingPathComponent("link"), withDestinationURL: parent.appendingPathComponent("real/inner")
        )
        try Fixtures.write("keep", to: "keep/precious.md", in: parent)
        let badSource = parent.appendingPathComponent("missing.git").absoluteString
        let dest = parent.appendingPathComponent("link/../keep") // `keep` by name, `real/keep` by the symlink
        await assertThrowsGitError { try await Repository.clone(from: badSource, to: dest) }
        XCTAssertEqual(try read("keep/precious.md", in: parent), "keep")
        XCTAssertEqual(try files.contentsOfDirectory(atPath: parent.appendingPathComponent("real").path), ["inner"])
    }
}
