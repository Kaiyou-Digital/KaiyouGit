import CLibGit2
import Foundation
@testable import KaiyouGit
import XCTest

/// Which URLs connect at all, and the ssh credential and host-key callbacks, driven offline. The live ssh
/// path is covered by the gated SSHIntegrationTests.
final class RemoteAuthTests: XCTestCase {
    private let key = Credentials.sshKey(user: "git", privateKey: "PEM", passphrase: nil)

    /// The callback tests call libgit2 without going through a library entry point, which would initialise it.
    override func setUp() {
        LibGit2.initialize()
    }

    private func makeRepo(origin: String) async throws -> Repository {
        let dir = try Fixtures.makeTempDir(for: self).appendingPathComponent("repo")
        let repo = try await Repository.initialize(at: dir)
        try Fixtures.write("1", to: "a.md", in: dir)
        try await repo.stageAll()
        try await repo.commit(message: "x", author: Author(name: "Test", email: "test@example.invalid"))
        try await repo.addRemote(name: "origin", url: origin)
        return repo
    }

    func testHTTPSThrowsUnsupportedBeforeConnecting() async throws {
        let dest = try Fixtures.makeTempDir(for: self).appendingPathComponent("clone")
        let auth = RemoteAuth(credentials: key, hostKeys: .pinned(sha256: []))
        await assertThrows(.unsupportedTransport("https")) {
            try await Repository.clone(from: "https://example.invalid/a/b.git", to: dest, auth: auth)
        }
        await assertThrows(.unsupportedTransport("http")) {
            try await Repository.clone(from: "http://example.invalid/a/b.git", to: dest)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))

        let repo = try await makeRepo(origin: "https://example.invalid/a/b.git")
        await assertThrows(.unsupportedTransport("https")) { try await repo.fetch(auth: auth) }
        await assertThrows(.unsupportedTransport("https")) { try await repo.push(refspec: "HEAD:refs/heads/main") }
    }

    func testSSHURLWithoutAuthThrows() async throws {
        let dest = try Fixtures.makeTempDir(for: self).appendingPathComponent("clone")
        for url in ["ssh://git@example.invalid/a/b.git", "git@example.invalid:a/b.git"] {
            await assertThrows(.authenticationFailed) { try await Repository.clone(from: url, to: dest) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))

        let repo = try await makeRepo(origin: "git@example.invalid:a/b.git")
        await assertThrows(.authenticationFailed) { try await repo.fetch() }
        await assertThrows(.authenticationFailed) { try await repo.push(refspec: "HEAD:refs/heads/main") }
    }

    /// Clone's `origin` is created as git would, `url.<base>.insteadOf` applied, and the rewritten URL is held to the
    /// same rule as the one given, so an ssh URL rewritten to https never connects. (libgit2 reads a rewrite from a
    /// global config the tests cannot redirect, so this drives clone's remote callback on a repository that has one.)
    func testCloneRemoteRewrittenToHTTPSIsUnsupported() async throws {
        let dir = try Fixtures.makeTempDir(for: self).appendingPathComponent("repo")
        let repo = try await Repository.initialize(at: dir)
        try await repo.setConfig("url.https://example.invalid/.insteadOf", "ssh://example.invalid/")
        let auth = RemoteAuth(credentials: key, hostKeys: .pinned(sha256: []))
        func create(_ name: String, _ url: String) -> GitError? {
            var remote: OpaquePointer?
            defer { git_remote_free(remote) }
            do {
                try RemoteContext(auth: auth, progress: nil).run { callbacks in
                    RemoteContext.createRemote(&remote, repo.handle, name, url, callbacks.payload)
                }
                return nil
            } catch {
                return error
            }
        }
        XCTAssertEqual(create("rewritten", "ssh://example.invalid/x"), .unsupportedTransport("https"))
        XCTAssertNil(create("kept", "ssh://other.invalid/x"))
    }

    func testSSHPinnedFingerprintAcceptsAndRejects() {
        let hash = Data((0 ..< 32).map { UInt8($0) }) // the SHA-256 of the server's host key
        let padded = hash.base64EncodedString()
        let fingerprint = String(padded.dropLast()) // unpadded, as GitHub publishes it
        let other = Data(repeating: 7, count: 32).base64EncodedString()
        func verdict(
            _ policy: HostKeyPolicy?,
            certType: git_cert_t = GIT_CERT_HOSTKEY_LIBSSH2,
            hashes: git_cert_ssh_t = GIT_CERT_SSH_SHA256
        ) -> GitError? {
            let auth = policy.map { RemoteAuth(credentials: key, hostKeys: $0) }
            return offerHostKey(hash, to: auth, certType: certType, hashes: hashes)
        }
        XCTAssertNil(verdict(.pinned(sha256: [fingerprint])))
        XCTAssertNil(verdict(.pinned(sha256: [other, "SHA256:" + fingerprint])))
        XCTAssertNil(verdict(.pinned(sha256: [padded])))
        XCTAssertEqual(verdict(.pinned(sha256: [other])), .hostKeyRejected)
        XCTAssertEqual(verdict(.pinned(sha256: [])), .hostKeyRejected)
        XCTAssertEqual(verdict(nil), .hostKeyRejected)
        XCTAssertEqual(verdict(.pinned(sha256: [fingerprint]), certType: GIT_CERT_X509), .hostKeyRejected)
        XCTAssertNil(verdict(.custom { $0.host == "example.invalid" && $0.sha256 == fingerprint }))
        XCTAssertEqual(verdict(.custom { _ in false }), .hostKeyRejected)
        // No SHA-256 from the server: refused before the closure could see a fingerprint that is not one.
        XCTAssertEqual(verdict(.custom { _ in true }, hashes: GIT_CERT_SSH_SHA1), .hostKeyRejected)
    }

    func testCredentialsOfferTheKeyOnceThenFail() {
        let context = RemoteContext(auth: RemoteAuth(credentials: key, hostKeys: .pinned(sha256: [])), progress: nil)
        var codes: [Int32] = []
        let allowed = [GIT_CREDENTIAL_USERNAME, GIT_CREDENTIAL_SSH_KEY, GIT_CREDENTIAL_SSH_KEY]
        XCTAssertThrowsError(try context.run { callbacks in
            for types in allowed {
                var credential: UnsafeMutablePointer<git_credential>?
                codes.append(callbacks.credentials!(
                    &credential,
                    "ssh://example.invalid/a",
                    nil,
                    types.rawValue,
                    callbacks.payload
                ))
                git_credential_free(credential)
            }
            return codes.last ?? 0
        }) { XCTAssertEqual($0 as? GitError, .authenticationFailed) }
        XCTAssertEqual(codes, [0, 0, GIT_EAUTH.rawValue])

        let none = RemoteContext(auth: nil, progress: nil)
        XCTAssertThrowsError(try none.run { callbacks in
            var credential: UnsafeMutablePointer<git_credential>?
            return callbacks.credentials!(
                &credential,
                "ssh://example.invalid/a",
                "git",
                GIT_CREDENTIAL_SSH_KEY.rawValue,
                callbacks.payload
            )
        }) { XCTAssertEqual($0 as? GitError, .authenticationFailed) }
    }

    /// Calls the certificate check libgit2 makes for an ssh server whose host key hashes to `sha256`.
    private func offerHostKey(
        _ sha256: Data, to auth: RemoteAuth?, certType: git_cert_t, hashes: git_cert_ssh_t
    ) -> GitError? {
        var cert = git_cert_hostkey()
        cert.parent.cert_type = certType
        cert.type = hashes
        withUnsafeMutableBytes(of: &cert.hash_sha256) { $0.copyBytes(from: sha256) }
        do {
            try RemoteContext(auth: auth, progress: nil).run { callbacks in
                withUnsafeMutablePointer(to: &cert) { pointer in
                    pointer.withMemoryRebound(to: git_cert.self, capacity: 1) {
                        callbacks.certificate_check!($0, 0, "example.invalid", callbacks.payload)
                    }
                }
            }
            return nil
        } catch {
            return error
        }
    }
}
