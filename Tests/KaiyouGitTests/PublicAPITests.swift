import KaiyouGit
import XCTest

/// Only the public API (no `@testable`), as an app that imports the package sees it.
final class PublicAPITests: XCTestCase {
    /// A caller can unit test its own `.custom` host-key closure.
    func testHostKeyCanBeMadeToTestACustomPolicy() {
        let trusted: @Sendable (HostKey) -> Bool = { $0.host == "github.com" && $0.sha256 == "abc" }
        XCTAssertTrue(trusted(HostKey(host: "github.com", sha256: "abc")))
        XCTAssertFalse(trusted(HostKey(host: "example.invalid", sha256: "abc")))
    }

    /// print, dump, interpolation and debug output never show the private key or its passphrase.
    func testCredentialsNeverPrintTheKeyOrPassphrase() {
        let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\nnot-a-real-key\n-----END OPENSSH PRIVATE KEY-----\n"
        let credentials = Credentials.sshKey(user: "git", privateKey: pem, passphrase: "hunter2")
        let auth = RemoteAuth(credentials: credentials, hostKeys: .pinned(sha256: ["abc"]))
        var dumped = ""
        dump(credentials, to: &dumped)
        dump(auth, to: &dumped)
        let shown = [
            String(describing: credentials), String(reflecting: credentials), "\(credentials)",
            String(describing: auth), String(reflecting: auth), "\(auth)", dumped,
        ]
        for text in shown {
            XCTAssertFalse(text.contains("PRIVATE KEY"), text)
            XCTAssertFalse(text.contains("not-a-real-key"), text)
            XCTAssertFalse(text.contains("hunter2"), text)
            XCTAssertTrue(text.contains("git"), text) // the user is not secret
        }
    }
}
