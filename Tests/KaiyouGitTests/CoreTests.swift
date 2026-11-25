import CLibGit2
@testable import KaiyouGit
import XCTest

final class CoreTests: XCTestCase {
    func testBackends() {
        XCTAssertEqual(LibGit2.sshBackend, "libssh2")
        XCTAssertEqual(LibGit2.httpsBackend, "openssl")
    }

    func testInitializeCreatesRepoOnMain() async throws {
        let dir = try Fixtures.makeTempDir(for: self).appendingPathComponent("nested/repo")
        _ = try await Repository.initialize(at: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path))
        _ = try await Repository.open(at: dir)
    }

    func testOpenMissingDirectoryThrowsNotFound() async throws {
        let dir = try Fixtures.makeTempDir(for: self).appendingPathComponent("missing")
        do {
            _ = try await Repository.open(at: dir)
            XCTFail("expected an error")
        } catch let GitError.notFound(message) {
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testOpenNonRepositoryDirectoryThrowsNotFound() async throws {
        let dir = try Fixtures.makeTempDir(for: self)
        do {
            _ = try await Repository.open(at: dir)
            XCTFail("expected an error")
        } catch let GitError.notFound(message) {
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testInitializeOnExistingRepositoryDoesNotThrow() async throws {
        let dir = try Fixtures.makeTempDir(for: self).appendingPathComponent("repo")
        _ = try await Repository.initialize(at: dir)
        _ = try await Repository.initialize(at: dir)
    }

    func testErrorMappingTable() {
        let net = Int32(GIT_ERROR_NET.rawValue), ssh = Int32(GIT_ERROR_SSH.rawValue)
        let http = Int32(GIT_ERROR_HTTP.rawValue), osClass = Int32(GIT_ERROR_OS.rawValue)
        struct Row {
            let code: Int32, errorClass: Int32, expected: GitError
        }
        let rows = [
            Row(code: GIT_EAUTH.rawValue, errorClass: osClass, expected: .authenticationFailed),
            Row(code: GIT_ECERTIFICATE.rawValue, errorClass: osClass, expected: .hostKeyRejected),
            Row(code: GIT_ENONFASTFORWARD.rawValue, errorClass: osClass, expected: .notFastForward),
            Row(code: GIT_ECONFLICT.rawValue, errorClass: osClass, expected: .wouldOverwriteLocalChanges),
            Row(code: GIT_ENOTFOUND.rawValue, errorClass: osClass, expected: .notFound("m")),
            Row(code: GIT_EUSER.rawValue, errorClass: osClass, expected: .cancelled),
            Row(code: GIT_ERROR.rawValue, errorClass: net, expected: .network("m")),
            Row(code: GIT_ERROR.rawValue, errorClass: ssh, expected: .network("m")),
            Row(code: GIT_ERROR.rawValue, errorClass: http, expected: .network("m")),
            Row(
                code: GIT_EEXISTS.rawValue, errorClass: osClass,
                expected: .other(class: osClass, code: GIT_EEXISTS.rawValue, message: "m")
            ),
        ]
        for row in rows {
            XCTAssertEqual(
                mapError(code: row.code, errorClass: row.errorClass, message: "m"), row.expected,
                "code \(row.code) class \(row.errorClass)"
            )
        }
        // libssh2 refusing the key itself (bad format, as observed live; wrong passphrase; bad key data) is a sign-in
        // failure. libgit2 puts the same prefix on a socket failure during sign-in, which is still a network one, as is
        // a session that cannot start.
        let prefix = "failed to authenticate SSH session: "
        let signIn = [
            "Unable to extract public key from private key file: Unsupported private key file format",
            "Unable to extract public key from private key file: Wrong passphrase or invalid/unrecognized private key "
                + "file format",
            "Invalid key data, not base64 encoded",
        ]
        for text in signIn {
            XCTAssertEqual(
                mapError(code: GIT_ERROR.rawValue, errorClass: ssh, message: prefix + text), .authenticationFailed, text
            )
        }
        for message in [prefix + "Unable to send userauth-publickey request", "failed to start SSH session: x"] {
            XCTAssertEqual(mapError(code: GIT_ERROR.rawValue, errorClass: ssh, message: message), .network(message))
        }
    }
}
