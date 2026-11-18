import Testing
@testable import TankardCore

/// 0.8.4: TankardVersion.string follows Tankard.app's Info.plist (the e2e's
/// re-versioned builds), and nothing else's.
struct V084VersionTests {
    @Test func tankardBundleUsesItsShortVersion() {
        #expect(TankardVersion.resolve(bundleIdentifier: "net.mindtricks.tankard", shortVersion: "0.8.4-e2e.0") == "0.8.4-e2e.0")
        #expect(TankardVersion.resolve(bundleIdentifier: "net.mindtricks.tankard.e2e.theme.123", shortVersion: "0.8.4") == "0.8.4")
    }

    @Test func otherProcessesUseTheSource() {
        // swift test's runner, the CLI (no bundle id), a lookalike prefix.
        #expect(TankardVersion.resolve(bundleIdentifier: "com.apple.dt.xctest.tool", shortVersion: "16.0") == TankardVersion.source)
        #expect(TankardVersion.resolve(bundleIdentifier: nil, shortVersion: "9.9.9") == TankardVersion.source)
        #expect(TankardVersion.resolve(bundleIdentifier: "net.mindtricks.tankardx", shortVersion: "9.9.9") == TankardVersion.source)
    }

    @Test func emptyOrMissingShortVersionUsesTheSource() {
        #expect(TankardVersion.resolve(bundleIdentifier: "net.mindtricks.tankard", shortVersion: nil) == TankardVersion.source)
        #expect(TankardVersion.resolve(bundleIdentifier: "net.mindtricks.tankard", shortVersion: " ") == TankardVersion.source)
    }

    @Test func underTestsTheStringIsTheSource() {
        #expect(TankardVersion.string == TankardVersion.source)
    }
}
