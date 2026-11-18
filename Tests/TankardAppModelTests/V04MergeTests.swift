import Foundation
import Observation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.4: where part A (pins) and part B (insights) meet, and the 0.3.1
// launch-fix rule applied to part B's settings.

@MainActor
struct V04HeldUpgradeTests {
    /// One rule for "upgrade everything": Upgrade all, the menu-bar count,
    /// notification keys and Upgrade vulnerable packages all leave a pinned
    /// package out, through `Package.isHeld`.
    @Test func pinnedVulnerablePackageIsLeftOutEverywhere() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0, pinned: ["openssl@4"]), settings: scanningSettings())
        await store.start()
        await store.insights.waitForIdle()
        let openssl = try #require(store.packages.first { $0.name == "openssl@4" })
        #expect(openssl.pinned && openssl.isHeld && openssl.isVulnerable && openssl.upgradeAvailable)
        #expect(!openssl.isUpgradeTarget)
        #expect(store.insights.isHeld(openssl))
        #expect(store.vulnerableUpgradeTargets.isEmpty)
        #expect(!store.upgradable.contains { $0.id == openssl.id })
        let summary = MenuBarSummary(packages: store.packages)
        #expect(summary.count == store.upgradable.count)
        #expect(!summary.rows.contains { $0.id == openssl.id })
        #expect(!UpgradeNotificationDiff.keys(store.packages).contains { $0.hasPrefix(openssl.id + "@") })
        #expect(store.pinnedUpgrades.map(\.name) == ["openssl@4"])
        store.upgradeVulnerable()
        #expect(store.upgrade == nil)
    }

    /// Self-updating casks (`brew outdated --greedy`) join Upgrade all, the
    /// count and notifications when that setting is on, unless pinned.
    @Test func selfUpdatingCasksCountUnlessPinned() async throws {
        func store(pinned: Set<String>) async -> AppStore {
            let settings = testSettings()
            settings.appManagementExplained = true
            InsightSettings(defaults: settings.defaults).includeSelfUpdatingApps = true
            let s = AppStore(deps: Demo.dependencies(.arm64, pace: 0, pinned: pinned), settings: settings)
            await s.start()
            return s
        }
        let open = await store(pinned: [])
        let ts = try #require(open.packages.first { $0.name == "tailscale-app" })
        #expect(ts.selfUpdatingUpgrade == true && ts.isUpgradeTarget)
        #expect(open.upgradable.contains { $0.id == ts.id })
        #expect(MenuBarSummary(packages: open.packages).count == open.upgradable.count)
        #expect(UpgradeNotificationDiff.keys(open.packages).contains("\(ts.id)@\(ts.currentVersion ?? "")"))

        let held = await store(pinned: ["tailscale-app"])
        let pinnedTS = try #require(held.packages.first { $0.name == "tailscale-app" })
        #expect(pinnedTS.pinned && pinnedTS.selfUpdatingUpgrade == true && !pinnedTS.isUpgradeTarget)
        #expect(!held.upgradable.contains { $0.id == pinnedTS.id })
        #expect(held.upgradable.count == open.upgradable.count - 1)
        #expect(MenuBarSummary(packages: held.packages).count == held.upgradable.count)
        #expect(!UpgradeNotificationDiff.keys(held.packages).contains { $0.hasPrefix(pinnedTS.id + "@") })
        #expect(held.pinnedUpgrades.map(\.name) == ["tailscale-app"])
    }

    /// Copy Upgrade Command copies what the detail pane shows: with "Don't
    /// quit running apps" on, a cask upgrade carries brew's variable.
    @Test func copyUpgradeCommandCarriesNoQuit() async throws {
        let settings = testSettings()
        settings.appManagementExplained = true
        InsightSettings(defaults: settings.defaults).dontQuitAppsDuringUpgrade = true
        let store = AppStore(deps: Demo.dependencies(.arm64, pace: 0), settings: settings)
        await store.start()
        let cask = try #require(store.upgradable.first { $0.kind == .cask })
        let formula = try #require(store.upgradable.first { $0.kind == .formula })
        func copied(_ p: Package) -> String? {
            let entries = ContextMenus.installed(p, dependents: [], dependencies: [], compileWarning: nil, busy: false,
                                                 kegPath: nil, upgradeCommand: store.insights.upgradeDisplay(for: p))
            guard case .copy(let s)? = entries.compactMap(\.item).first(where: { $0.id == "copy-command" })?.action else { return nil }
            return s
        }
        #expect(copied(cask) == "HOMEBREW_NO_UPGRADE_QUIT_CASKS=1 brew upgrade --cask \(cask.qualifiedName)")
        #expect(copied(formula) == "brew upgrade --formula \(formula.qualifiedName)")
        store.insights.settings.dontQuitAppsDuringUpgrade = false
        #expect(copied(cask) == "brew upgrade --cask \(cask.qualifiedName)")
    }
}

@MainActor
struct V04SettingsLaunchRuleTests {
    /// The 0.3.1 rule for every new setting: writing the value it already
    /// has notifies no observer and calls no onChange; a real change does.
    @Test func unchangedInsightSettingWritesNotifyNothing() {
        let d = TestDefaults.fresh()
        let s = InsightSettings(defaults: d)
        var changes: [InsightSettings.Change] = []
        s.onChange = { changes.append($0) }

        func unchanged(_ label: String, read: @escaping () -> Void, write: () -> Void) {
            let notified = Flag()
            withObservationTracking { read() } onChange: { notified.set() }
            write()
            #expect(!notified.value, "\(label): an unchanged write notified observers")
        }
        unchanged("includeSelfUpdatingApps", read: { _ = s.includeSelfUpdatingApps }) { s.includeSelfUpdatingApps = s.includeSelfUpdatingApps }
        unchanged("dontQuitAppsDuringUpgrade", read: { _ = s.dontQuitAppsDuringUpgrade }) { s.dontQuitAppsDuringUpgrade = s.dontQuitAppsDuringUpgrade }
        unchanged("scanVulnerabilitiesOnRefresh", read: { _ = s.scanVulnerabilitiesOnRefresh }) { s.scanVulnerabilitiesOnRefresh = s.scanVulnerabilitiesOnRefresh }
        unchanged("notifyNewVulnerabilities", read: { _ = s.notifyNewVulnerabilities }) { s.notifyNewVulnerabilities = s.notifyNewVulnerabilities }
        unchanged("seenVulnerabilities", read: { _ = s.seenVulnerabilities }) { s.seenVulnerabilities = s.seenVulnerabilities }
        s.seenVulnerabilities = ["a"]
        unchanged("seenVulnerabilities (set)", read: { _ = s.seenVulnerabilities }) { s.seenVulnerabilities = ["a"] }
        #expect(changes.isEmpty)

        // Real changes still notify, call onChange and persist.
        let notified = Flag()
        withObservationTracking { _ = s.includeSelfUpdatingApps } onChange: { notified.set() }
        s.includeSelfUpdatingApps = true
        s.notifyNewVulnerabilities = true
        s.dontQuitAppsDuringUpgrade = true
        s.scanVulnerabilitiesOnRefresh = false
        #expect(notified.value)
        #expect(changes.count == 2)
        let reread = InsightSettings(defaults: d)
        #expect(reread.includeSelfUpdatingApps && reread.notifyNewVulnerabilities && reread.dontQuitAppsDuringUpgrade)
        #expect(!reread.scanVulnerabilitiesOnRefresh)
        #expect(reread.seenVulnerabilities == ["a"])
    }
}
