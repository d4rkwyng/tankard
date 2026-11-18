import Foundation
import Testing
@testable import TankardAppModel
import TankardCore

// v0.8.4: the menu-bar panel cut "3.29.15,86776fcb… → 3.30.14,5f54c817…"
// from the front, so only the hash's tail showed.
struct V084MenuBarVersionTests {
    @Test(arguments: [
        // cursor and google-chrome, as brew gives them on this Mac.
        ("3.29.15,86776fcb52ca505783155631089b65d646f9b03f", "3.30.14,5f54c8173e5552412beb40702adac16275677fa0", "3.29.15 → 3.30.14"),
        ("157.0.8103.51", "158.0.8127.37", "157.0.8103.51 → 158.0.8127.37"),
        ("5.8.3", "5.8.4", "5.8.3 → 5.8.4"),
        // Only the build differs: it stays, shortened if it's a hash.
        ("1.2,100", "1.2,101", "1.2 (100) → 1.2 (101)"),
        ("2.0,86776fcb52ca505783155631089b65d646f9b03f", "2.0,5f54c8173e5552412beb40702adac16275677fa0", "2.0 (86776fc) → 2.0 (5f54c81)"),
        // A bare commit hash (a HEAD-ish cask or formula): 7 characters.
        ("86776fcb52ca505783155631089b65d646f9b03f", "5f54c8173e5552412beb40702adac16275677fa0", "86776fc → 5f54c81"),
        // Hex-looking but short, or not hex: as is.
        ("20261108", "20261117", "20261108 → 20261117"),
        ("latest", "latest", "latest → latest"),
    ])
    func pair(installed: String, current: String, shown: String) {
        #expect(MenuBarSummary.versionPair(installed, current) == shown)
    }

    @Test func missingCurrent() {
        #expect(MenuBarSummary.versionPair("1.0", nil) == "1.0 → ?")
    }

    @Test func rowKeepsTheFullPairForTheTooltip() throws {
        var p = versioned("cursor", "3.29.15,86776fcb52ca505783155631089b65d646f9b03f",
                          "3.30.14,5f54c8173e5552412beb40702adac16275677fa0", kind: .cask)
        p.upgradeAvailable = true
        let row = try #require(MenuBarSummary(packages: [p]).rows.first)
        #expect(row.versions == "3.29.15 → 3.30.14")
        #expect(row.fullVersions == "3.29.15,86776fcb52ca505783155631089b65d646f9b03f → 3.30.14,5f54c8173e5552412beb40702adac16275677fa0")
    }
}
