import Foundation
import Testing
@testable import TankardCore
@testable import TankardAppModel

// 0.8.6: Settings "Show the number of upgrades in the menu bar" (default
// on). Off: the icon only (full or empty tankard); the count stays in the
// tooltip and the panel.

@MainActor
struct V086MenuBarCountTests {
    static func summary(_ n: Int) -> MenuBarSummary {
        let pkgs = (0..<n).map { i -> Package in
            var p = Package.command("p\(i)")
            p.installedVersion = "1"
            p.currentVersion = "2"
            p.upgradeAvailable = true
            return p
        }
        return MenuBarSummary(packages: pkgs)
    }

    @Test func defaultOnAndPersisted() {
        let d = TestDefaults.fresh()
        let s = AppSettings(defaults: d)
        #expect(s.showMenuBarCount)
        s.showMenuBarCount = false
        #expect(AppSettings(defaults: d).showMenuBarCount == false)
        #expect(d.object(forKey: "showMenuBarCount") as? Bool == false)
    }

    @Test func labelHidesOnlyTheNumber() {
        let s = Self.summary(5)
        #expect(s.label(showCount: true).badge == "5")
        #expect(s.label(showCount: false).badge == nil)
        // The icon still says whether upgrades wait, and the tooltip has the count.
        #expect(s.label(showCount: false).full && s.label(showCount: true).full)
        #expect(s.title == "5 upgrades ready")
        #expect(!Self.summary(0).label(showCount: true).full && Self.summary(0).label(showCount: true).badge == nil)
        #expect(Self.summary(150).label(showCount: true).badge == "99+")
    }
}
