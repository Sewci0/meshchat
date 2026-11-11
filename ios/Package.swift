// swift-tools-version: 6.0
// MeshChat for iOS: the parts that don't need a UI, as Swift packages the app (MeshChat.xcodeproj,
// generated from project.yml) depends on. They build and test on macOS too: `swift test`.
import Foundation
import PackageDescription

// With only the Command Line Tools (see test.sh), Swift Testing's Foundation overlay has no module, so
// the test targets build without cross-import overlays. Only theirs: the app's screens need SwiftUI's.
let cltTesting = ProcessInfo.processInfo.environment["MESHCHAT_CLT_TESTING"] != nil
let testSettings: [SwiftSetting] = cltTesting ? [.unsafeFlags(["-Xfrontend", "-disable-cross-import-overlays"])] : []

let package = Package(
    name: "MeshChatKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        // the MeshCore companion protocol, over Bluetooth or WiFi
        .library(name: "MeshCoreKit", targets: ["MeshCoreKit"]),
        // the app's memory and logic: history, sending with retries, routes, rooms, listening
        .library(name: "MeshChatCore", targets: ["MeshChatCore"]),
        // the screens (SwiftUI); the iOS app target is a thin shell around them
        .library(name: "MeshChatUI", targets: ["MeshChatUI"]),
        // a command-line tool for checking a radio from a Mac
        .executable(name: "meshcore-cli", targets: ["meshcore-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.12.0"),
    ],
    targets: [
        .target(name: "MeshCoreKit", path: "Sources/MeshCoreKit"),
        .target(name: "MeshChatCore", dependencies: ["MeshCoreKit", .product(name: "GRDB", package: "GRDB.swift")], path: "Sources/MeshChatCore"),
        .target(name: "MeshChatUI", dependencies: ["MeshChatCore", "MeshCoreKit"], path: "Sources/MeshChatUI"),
        // a radio in memory that answers like MeshCore's firmware, for the tests
        .target(name: "MeshChatTestSupport", dependencies: ["MeshCoreKit"], path: "Tests/Support"),
        .testTarget(name: "MeshChatCoreTests", dependencies: ["MeshChatCore", "MeshCoreKit", "MeshChatTestSupport"],
                    path: "Tests/MeshChatCoreTests", swiftSettings: testSettings),
        .testTarget(name: "MeshChatUITests", dependencies: ["MeshChatUI", "MeshChatCore", "MeshCoreKit", "MeshChatTestSupport"],
                    path: "Tests/MeshChatUITests", swiftSettings: testSettings),
        .executableTarget(name: "meshcore-cli", dependencies: ["MeshCoreKit"], path: "Sources/meshcore-cli"),
        .testTarget(name: "MeshCoreKitTests", dependencies: ["MeshCoreKit"], path: "Tests/MeshCoreKitTests", swiftSettings: testSettings),
    ]
)
