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

// 0.8.4: About kept wrapping "BSD-2-" / "Clause.".
struct V084AboutLicenceTests {
    @Test func licenceNameDoesNotBreak() {
        let joined = "BSD-\u{2060}2-\u{2060}Clause"
        #expect(AboutInfo.keepTogether("Homebrew © Homebrew contributors, BSD-2-Clause.") == "Homebrew © Homebrew contributors, \(joined).")
        #expect(AboutInfo.homebrewCopyright.contains(joined))
        #expect(AboutInfo.licence.contains(joined))
        // Only the joiners were added.
        #expect(AboutInfo.homebrewCopyright.replacingOccurrences(of: "\u{2060}", with: "") == "Homebrew © Homebrew contributors, BSD-2-Clause.")
        #expect(AboutInfo.keepTogether("MIT") == "MIT")
    }
}

// 0.8.4: menu items that open a confirmation end in "…" and name the package.
struct V084MenuWordingTests {
    @Test func confirmationItemsEndInEllipsis() {
        var xz = versioned("xz", "5.8.1", "5.8.2")
        xz.upgradeAvailable = true
        #expect(ContextMenus.upgradeTitle(xz, compiles: false) == "Upgrade xz")
        #expect(ContextMenus.upgradeTitle(xz, compiles: true) == "Upgrade xz (compiles)…")
        var win = versioned("windows-app", "1", "2", kind: .cask)
        win.installsPkg = true // the plan asks for the password first
        #expect(ContextMenus.upgradeTitle(win, compiles: false) == "Upgrade windows-app…")
        #expect(ContextMenus.installTitle("hello", compiles: false) == "Install hello")
        #expect(ContextMenus.installTitle("node-red", compiles: true) == "Install node-red (compiles)…")
        let row = ContextMenus.menuBarRow(xz, compileWarning: CompileWarning(context: .upgrade), busy: false)
        guard case .item(let m)? = row.first else { Issue.record("no item"); return }
        #expect(m.title == "Upgrade xz (compiles)…")
    }
}

// 0.8.4: the open menu-bar panel shrinks when rows go, top edge kept.
struct V084MenuBarPanelFrameTests {
    @Test func shrinksKeepingTheTopEdge() throws {
        let f = CGRect(x: 2000, y: 900, width: 300, height: 510) // top at 1410
        let s = try #require(MenuBarPanelFrame.shrunk(frame: f, contentHeight: 510, fitting: 430))
        #expect(s == CGRect(x: 2000, y: 980, width: 300, height: 430))
        #expect(s.maxY == f.maxY)
    }

    @Test func leavesGrowingAndEqualAlone() {
        let f = CGRect(x: 0, y: 0, width: 300, height: 400)
        #expect(MenuBarPanelFrame.shrunk(frame: f, contentHeight: 400, fitting: 400) == nil)
        #expect(MenuBarPanelFrame.shrunk(frame: f, contentHeight: 400, fitting: 400.3) == nil)
        #expect(MenuBarPanelFrame.shrunk(frame: f, contentHeight: 400, fitting: 520) == nil) // SwiftUI grows it
        #expect(MenuBarPanelFrame.shrunk(frame: f, contentHeight: 400, fitting: 0) == nil)   // not laid out yet
    }
}
