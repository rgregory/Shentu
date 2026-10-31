// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Shentu adds no sandbox logic of its own: profiles, launching and the deny log come from
// MenshenCore, so the two apps can't drift. MENSHEN_PATH points the build at another checkout
// (a Menshen worktree whose changes aren't merged yet); the default is the sibling folder.
let menshenPath = ProcessInfo.processInfo.environment["MENSHEN_PATH"] ?? "../menshen"
// SwiftPM names a local package after its folder.
let menshenPackage = URL(fileURLWithPath: menshenPath).lastPathComponent

// Same workaround as Menshen: with only the Command Line Tools, point the compiler at Swift
// Testing's macro plugin explicitly.
let cltTestingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testSettings: [SwiftSetting] = FileManager.default.fileExists(atPath: cltTestingPlugins)
    ? [.unsafeFlags(["-plugin-path", cltTestingPlugins])]
    : []

let package = Package(
    name: "shentu",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Shentu", targets: ["Shentu"]),
    ],
    dependencies: [
        .package(path: menshenPath),
    ],
    targets: [
        .executableTarget(name: "Shentu", dependencies: ["ShentuCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "ShentuCore", dependencies: [.product(name: "MenshenCore", package: menshenPackage)]),
        .testTarget(
            name: "ShentuTests",
            dependencies: ["ShentuCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: testSettings
        ),
    ]
)
