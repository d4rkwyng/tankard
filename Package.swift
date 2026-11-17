// swift-tools-version: 6.0
// 6.0 is the newest tools version the Intel test VM's Command Line Tools
// (Swift 6.0.3, CLT 16.2 on macOS 14) understand.
import PackageDescription

let package = Package(
    name: "tankard",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TankardCore", targets: ["TankardCore"]),
        .executable(name: "tankard", targets: ["tankard"]),
        .executable(name: "TankardApp", targets: ["TankardApp"]),
    ],
    targets: [
        // Models, brew JSON decoding, status classification, version
        // comparison, environment construction and Intelbrew detection.
        // No UI dependencies: the SwiftUI app (step 2) links this.
        .target(name: "TankardCore"),

        .executableTarget(
            name: "tankard",
            dependencies: ["TankardCore"]
        ),

        // The app's state and plumbing, without SwiftUI views: the
        // @Observable store, the FIFO command queue, the CR-aware log line
        // assembler, the status cache and demo mode. Tested on its own.
        .target(
            name: "TankardAppModel",
            dependencies: ["TankardCore"],
            resources: [.copy("Resources/Demo")]
        ),

        // The SwiftUI app. Scripts/bundle-app.sh wraps it in Tankard.app.
        // Localizations: <lang>.lproj/Localizable.strings, generated from
        // Resources/Localizable.xcstrings by Scripts/l10n.py compile (the
        // CLT have no xcstringstool to compile the catalog itself).
        .executableTarget(
            name: "TankardApp",
            dependencies: ["TankardCore", "TankardAppModel"],
            resources: [
                .copy("Resources/intelbrew-mug.png"), .copy("Resources/tankard-mark.png"),
                .process("Resources/Localizations"),
            ]
        ),

        .testTarget(
            name: "TankardAppModelTests",
            dependencies: ["TankardAppModel", "TankardCore"]
        ),

        .testTarget(
            name: "TankardCoreTests",
            dependencies: ["TankardCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
