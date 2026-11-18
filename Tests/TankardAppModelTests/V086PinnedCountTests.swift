import Foundation
import Testing
@testable import TankardCore
@testable import TankardAppModel

// 0.8.6 (UI details M3): with every upgrade pinned the header said "5
// upgrades ready" while the button said "Up to date" and the menu bar
// "Everything is up to date". The header now counts what Upgrade All takes.
@MainActor
struct V086PinnedCountTests {
    func pkg(_ name: String, pinned: Bool = false) -> Package {
        var p = Package.command(name)
        p.id = "formula:homebrew/core/\(name)"
        p.installedVersion = "1"
        p.currentVersion = "2"
        p.upgradeAvailable = true
        p.upgradeHasBottle = true
        p.pinned = pinned
        return p
    }

    @Test func headerCountsTargetsAndNamesTheRest() throws {
        let all = [pkg("a", pinned: true), pkg("b", pinned: true), pkg("c"), pkg("d"), pkg("e")]
        let s = StatusSummary(packages: all)
        let (ready, detail) = try #require(SummaryText.upgrades(s, targets: all.filter(\.isUpgradeTarget)))
        #expect(ready == "3 upgrades ready")
        #expect(detail == "(3 with bottles) · 2 not included")
        #expect(SummaryText.upgrades(StatusSummary(packages: [pkg("a", pinned: true)]), targets: []) == nil)
    }

    @Test func detailLineSaysWhyItIsLeftOut() {
        #expect(UpgradeBanner.text(pkg("sqlite")) == "Upgrade ready: 1 → 2")
        #expect(UpgradeBanner.text(pkg("sqlite", pinned: true)) == "Newer version: 1 → 2 (pinned: upgrades leave it)")
        var skipped = pkg("xz")
        skipped.versionSkipped = true
        #expect(UpgradeBanner.text(skipped) == "Newer version: 1 → 2 (you skipped this version)")
    }
}
