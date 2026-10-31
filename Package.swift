// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Standalone: everything Shentu needs is in this folder. Sources/MenshenCore is Menshen's
// sandboxing library, copied unmodified (source commit in Sources/MenshenCore/VENDORED.md);
// Shentu's own code is ShentuCore (choices → Restricted Sandbox) and the app.

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
    targets: [
        .executableTarget(name: "Shentu", dependencies: ["ShentuCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "ShentuCore", dependencies: ["MenshenCore"]),
        .target(name: "MenshenCore", exclude: ["VENDORED.md"]),
        .testTarget(
            name: "ShentuTests",
            dependencies: ["ShentuCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: testSettings
        ),
    ]
)
