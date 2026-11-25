import Foundation
@testable import KaiyouGit
import XCTest

/// Clone's own cleanup after a failure, called directly (RemoteTests covers it through real clones).
final class CloneCleanupTests: XCTestCase {
    /// When git_clone itself refuses an existing destination because it is no longer empty (another process wrote to
    /// it after the check in clone), the `.git` in it is that process's and is kept; after any other failure a `.git`
    /// left in an existing destination is the clone's and goes. Called directly because nothing runs between clone's
    /// check and git_clone's own, so no test can write there in between.
    func testCleanupKeepsAGitDirectoryTheCloneDidNotMake() throws {
        let dest = try Fixtures.makeTempDir(for: self)
        try Fixtures.write("theirs", to: ".git/sentinel", in: dest)
        removeWhatCloneMade(created: nil, in: dest, refused: true)
        let sentinel = try String(contentsOf: dest.appendingPathComponent(".git/sentinel"), encoding: .utf8)
        XCTAssertEqual(sentinel, "theirs")
        removeWhatCloneMade(created: nil, in: dest, refused: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent(".git").path))
    }
}
