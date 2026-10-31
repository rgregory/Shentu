// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Everything Shentu needs is in this folder: ShentuSandbox (Seatbelt profiles, launch, deny log),
// ShentuCore (the pop-up's choices → a Restricted Sandbox) and the app.

// Same workaround as Shentu: with only the Command Line Tools, point the compiler at Swift
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
        .target(name: "ShentuCore", dependencies: ["ShentuSandbox"]),
        .target(name: "ShentuSandbox"),
        .testTarget(
            name: "ShentuTests",
            dependencies: ["ShentuCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: testSettings
        ),
    ]
)
