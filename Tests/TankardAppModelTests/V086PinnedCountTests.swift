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

// 0.8.6 (UI details M2): sheets fit the window.
struct V086SheetHeightTests {
    @Test func sheetsShrinkToTheWindowNotBelowTheMinimum() {
        #expect(SheetHeight.fit(620, room: nil) == 620)          // before layout
        #expect(SheetHeight.fit(620, room: 900) == 620)          // room to spare
        #expect(SheetHeight.fit(620, room: 600) == 584)          // default window: buttons stay in
        #expect(SheetHeight.fit(620, room: 430) == 414)          // minimum window
        #expect(SheetHeight.fit(620, room: 200) == SheetHeight.minimum)
        #expect(SheetHeight.fit(480, room: 600) == 480)
    }
}

// 0.8.6 (UI details M8): the detail pane narrows in a narrow window.
struct V086DetailWidthTests {
    @Test func narrowWindowNarrowPane() {
        #expect(DetailPaneWidth.width(window: nil) == 272)
        #expect(DetailPaneWidth.width(window: 1040) == 272)
        #expect(DetailPaneWidth.width(window: 820) == 224)
        // Table minimums (150+80+80+120+64) and spacing still fit beside it at 820.
        let columns: Double = 150 + 80 + 80 + 120 + 64 + 85
        let left: Double = 820 - DetailPaneWidth.width(window: 820) - 1
        #expect(left >= columns)
    }
}

// 0.8.6 (UI details L10): Homebrew ▸ Upgrade All… (⇧⌘U), Upgrade <name> (⌘U).
@MainActor
struct V086UpgradeMenuTests {
    @Test func upgradeSelectedNeedsAnUpgradableSelection() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: testSettings())
        await store.start()
        #expect(store.selectedUpgradeTarget == nil)
        #expect(UpgradeMenu.selectedTitle(nil) == "Upgrade Selected")
        let p = try #require(store.upgradable.first)
        store.selection = p.id
        #expect(store.selectedUpgradeTarget?.id == p.id)
        #expect(UpgradeMenu.selectedTitle(store.selectedUpgradeTarget) == "Upgrade \(p.name)")
        let current = try #require(store.packages.first { !$0.upgradeAvailable })
        store.selection = current.id
        #expect(store.selectedUpgradeTarget == nil)
        store.requestUpgradeAllPlan()
        #expect(store.upgradePlan != nil)
    }
}
