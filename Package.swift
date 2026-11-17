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
        .executable(name: "tankard-askpass", targets: ["tankard-askpass"]),
    ],
    targets: [
        // Models, brew JSON decoding, status classification, version
        // comparison, environment construction and Intelbrew detection.
        // No UI dependencies: the SwiftUI app (step 2) links this.
        .target(name: "TankardCore"),

        // 0.8.3: what the sudo password helper and the app share (variable
        // names, reading the request, the dialog's words). Foundation only.
        .target(name: "AskpassSupport"),

        // 0.8.3: the helper itself, Tankard.app/Contents/MacOS/tankard-askpass
        // (SUDO_ASKPASS for brew's sudo). AppKit; nothing else linked.
        .executableTarget(
            name: "tankard-askpass",
            dependencies: ["AskpassSupport"]
        ),

        .executableTarget(
            name: "tankard",
            dependencies: ["TankardCore"]
        ),

        // The app's state and plumbing, without SwiftUI views: the
        // @Observable store, the FIFO command queue, the CR-aware log line
        // assembler, the status cache and demo mode. Tested on its own.
        .target(
            name: "TankardAppModel",
            dependencies: ["TankardCore", "AskpassSupport"],
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
            dependencies: ["TankardAppModel", "TankardCore", "AskpassSupport"]
        ),

        .testTarget(
            name: "TankardCoreTests",
            dependencies: ["TankardCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
