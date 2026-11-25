// swift-tools-version: 6.0
import Foundation
import PackageDescription

/// KAIYOUGIT_LOCAL_XCFRAMEWORK points at a locally built CLibGit2.xcframework (for development and tests).
let localXCFramework = ProcessInfo.processInfo.environment["KAIYOUGIT_LOCAL_XCFRAMEWORK"] ?? ""
let clibgit2: Target = if !localXCFramework.isEmpty {
    .binaryTarget(name: "CLibGit2", path: localXCFramework)
} else {
    .binaryTarget(
        name: "CLibGit2",
        url: "https://github.com/Kaiyou-Digital/KaiyouGit/releases/download/v0.1.0/CLibGit2.xcframework.zip",
        checksum: "19d44fe31dbd24bcad3e8b707003b303258168327d973be7ecc056854b5373e9"
    )
}

let package = Package(
    name: "KaiyouGit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "KaiyouGit", targets: ["KaiyouGit"]),
    ],
    targets: [
        clibgit2,
        .target(name: "KaiyouGit", dependencies: ["CLibGit2"]),
        .testTarget(name: "KaiyouGitTests", dependencies: ["KaiyouGit"]),
    ]
)
