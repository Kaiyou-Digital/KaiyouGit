import CryptoKit
import Foundation
@testable import KaiyouGit
import os
import XCTest

/// Live ssh tests against a scratch remote, run by hand and skipped unless all three variables are set:
///
/// - `KAIYOUGIT_SSH_TEST_URL`: the remote, for example `ssh://git@github.com/<owner>/<scratch-repo>.git`.
/// - `KAIYOUGIT_SSH_TEST_KEY`: path to a write-enabled private key file for that remote (read into memory here).
/// - `KAIYOUGIT_SSH_TEST_HOSTKEYS`: comma separated host-key fingerprints to pin (unpadded base64 SHA-256).
/// - `KAIYOUGIT_SSH_TEST_EMPTY_URL` (optional): an EMPTY repository the key can read, for the empty-remote check.
///
/// The tests only create and delete their own `kaiyougit-test-<id>` branches, and fetch only those. On the iOS
/// simulator the variables need the `TEST_RUNNER_` prefix.
final class SSHIntegrationTests: XCTestCase {
    private let author = Author(name: "Test", email: "test@example.invalid")

    /// A fresh ed25519 key, authorised nowhere, as OpenSSH writes one unencrypted (`openssh-key-v1`), made at run time
    /// so no private key is ever committed.
    static func makeUnknownKey() -> String {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation
        func uint32(_ value: UInt32) -> Data {
            withUnsafeBytes(of: value.bigEndian) { Data($0) }
        }
        func string(_ bytes: Data) -> Data {
            uint32(UInt32(bytes.count)) + bytes
        }
        let publicBlob = string(Data("ssh-ed25519".utf8)) + string(publicKey)
        let check = uint32(UInt32.random(in: 0 ... .max))
        var secret = check + check + publicBlob + string(key.rawRepresentation + publicKey)
        secret += string(Data("kaiyougit-test".utf8))
        secret += Data((0 ..< (8 - secret.count % 8) % 8).map { UInt8($0 + 1) }) // pad to the 8-byte block
        let none = string(Data("none".utf8))
        let body = Data("openssh-key-v1\0".utf8) + none + none + string(Data()) + uint32(1) + string(publicBlob)
            + string(secret)
        let text = body.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(text)\n-----END OPENSSH PRIVATE KEY-----\n"
    }

    private struct Config {
        let url: String
        let key: String
        let hostKeys: Set<String>

        func auth(key: String? = nil, hostKeys: Set<String>? = nil) -> RemoteAuth {
            RemoteAuth(
                credentials: .sshKey(user: "git", privateKey: key ?? self.key, passphrase: nil),
                hostKeys: .pinned(sha256: hostKeys ?? self.hostKeys)
            )
        }
    }

    private func config() throws -> Config {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["KAIYOUGIT_SSH_TEST_URL"], let keyPath = env["KAIYOUGIT_SSH_TEST_KEY"],
              let hostKeys = env["KAIYOUGIT_SSH_TEST_HOSTKEYS"]
        else { throw XCTSkip("set KAIYOUGIT_SSH_TEST_URL, _KEY and _HOSTKEYS to run the live ssh tests") }
        let key = try String(contentsOfFile: keyPath, encoding: .utf8)
        return Config(url: url, key: key, hostKeys: Set(hostKeys.split(separator: ",").map(String.init)))
    }

    /// A new local repository with one commit and `origin` set to `url`.
    private func makeRepo(origin url: String, fetching branch: String? = nil) async throws -> Repository {
        let dir = try Fixtures.makeTempDir(for: self).appendingPathComponent("repo")
        let repo = try await Repository.initialize(at: dir)
        try Fixtures.write("hello", to: "a.md", in: dir)
        try await repo.stageAll()
        try await repo.commit(message: "test", author: author)
        try await repo.addRemote(name: "origin", url: url)
        if let branch { // fetch only the throwaway branch, never the scratch repo's whole history
            try await repo.setConfig("remote.origin.fetch", "+refs/heads/\(branch):refs/remotes/origin/\(branch)")
        }
        return repo
    }

    private func assertFetchFails(_ config: Config, auth: RemoteAuth) async throws -> GitError {
        let repo = try await makeRepo(origin: config.url)
        do {
            try await repo.fetch(auth: auth)
        } catch let error as GitError {
            return error
        }
        XCTFail("fetch succeeded")
        return .cancelled
    }

    func testSSHCloneCommitPush() async throws {
        let config = try config()
        let auth = config.auth()
        let branch = "kaiyougit-test-\(UUID().uuidString.prefix(8).lowercased())"
        let source = try await makeRepo(origin: config.url)
        // From the push until the test deletes the branch itself, a teardown deletes it if the test throws in between,
        // and reports a deletion that fails: a branch left on the remote is a failure, not something to ignore.
        let onRemote = OSAllocatedUnfairLock(initialState: true)
        addTeardownBlock {
            guard onRemote.withLock({ $0 }) else { return }
            do {
                try await source.push(refspec: ":refs/heads/\(branch)", auth: auth)
            } catch {
                XCTFail("the throwaway branch \(branch) may be left on the remote: \(error)")
            }
        }

        try await source.push(refspec: "HEAD:refs/heads/\(branch)", auth: auth)
        let pushed = try await source.resolve("HEAD")

        let copy = try await makeRepo(origin: config.url, fetching: branch)
        try await copy.fetch(auth: auth)
        let fetched = try await copy.resolve("origin/\(branch)")
        XCTAssertEqual(fetched, pushed)

        try await source.push(refspec: ":refs/heads/\(branch)", auth: auth)
        onRemote.withLock { $0 = false }
        let after = try await makeRepo(origin: config.url, fetching: branch) // fetching a missing ref is not an error
        try await after.fetch(auth: auth)
        let gone = try await after.resolve("origin/\(branch)")
        XCTAssertNil(gone)
    }

    func testRemoteRefsLiveSSH() async throws {
        let config = try config()
        let refs = try await Repository.remoteRefs(url: config.url, auth: config.auth())
        XCTAssertTrue(refs.contains { $0.name == "refs/heads/main" }, "\(refs.map(\.name))")
    }

    /// An empty remote advertises only a placeholder line; it must not come back as a ref.
    func testRemoteRefsOfEmptyRemoteLiveSSH() async throws {
        let config = try config()
        guard let empty = ProcessInfo.processInfo.environment["KAIYOUGIT_SSH_TEST_EMPTY_URL"] else {
            throw XCTSkip("set KAIYOUGIT_SSH_TEST_EMPTY_URL to an empty repository to run this")
        }
        let refs = try await Repository.remoteRefs(url: empty, auth: config.auth())
        XCTAssertEqual(refs, [], "\(refs)")
    }

    func testWrongHostKeyIsRejected() async throws {
        let config = try config()
        let made = Set(["AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"])
        let error = try await assertFetchFails(config, auth: config.auth(hostKeys: made))
        XCTAssertEqual(error, .hostKeyRejected)
    }

    #if os(macOS)
        /// Offline: the made-up key is a well-formed one (ssh-keygen derives its public key), so the wrong-key test
        /// below is not a second malformed-key test.
        func testUnknownKeyIsAWellFormedOpenSSHKey() throws {
            let file = try Fixtures.makeTempDir(for: self).appendingPathComponent("id_ed25519")
            try Data(Self.makeUnknownKey().utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            process.arguments = ["-y", "-f", file.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let out = String(bytes: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertTrue(out.hasPrefix("ssh-ed25519 "), out)
        }
    #endif

    func testWrongPrivateKeyFailsAuthentication() async throws {
        let config = try config()
        let error = try await assertFetchFails(config, auth: config.auth(key: Self.makeUnknownKey()))
        XCTAssertEqual(error, .authenticationFailed)
    }

    /// libssh2 reports "failed to authenticate SSH session: Unable to extract public key from private key file ...".
    func testMalformedKeyFails() async throws {
        let config = try config()
        let error = try await assertFetchFails(config, auth: config.auth(key: "not a key"))
        XCTAssertEqual(error, .authenticationFailed)
    }
}
