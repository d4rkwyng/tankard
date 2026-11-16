// swift-tools-version: 6.0
// 6.0 is the newest tools version the Intel test VM's Command Line Tools
// (Swift 6.0.3, CLT 16.2 on macOS 14) understand.
import PackageDescription

let package = Package(
    name: "tankard",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TankardCore", targets: ["TankardCore"]),
        .executable(name: "tankard", targets: ["tankard"]),
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

        .testTarget(
            name: "TankardCoreTests",
            dependencies: ["TankardCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
