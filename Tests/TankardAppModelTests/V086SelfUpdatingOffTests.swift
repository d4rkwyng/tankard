import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.6 (walkthrough M5): brew 7 lists a self-updating cask (auto_updates)
// as outdated by default whenever the app bundle is older than the cask
// (HOMEBREW_UPGRADE_AUTO_UPDATES_CASKS defaults on; checked on brew
// 7.0.14: `brew outdated --cask` listed cursor, github, google-chrome,
// grok-bot, obsidian and visual-studio-code; with
// HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS=1, none). With "Include
// self-updating apps" off, the setting said they were left out, yet
// Upgrade All replaced them. Off now means off: they stay visible, but out
// of Upgrade All, the counts and auto-update; a manual Upgrade still works.
@MainActor
struct V086SelfUpdatingOffTests {
    func cask(_ token: String, autoUpdates: Bool) -> Package {
        var p = Package.command(token)
        p.id = "cask:homebrew/cask/\(token)"
        p.kind = .cask
        p.tap = "homebrew/cask"
        p.fullName = token
        p.status = .cask
        p.installedVersion = "1"
        p.currentVersion = "2"
        p.upgradeAvailable = true
        p.autoUpdates = autoUpdates
        return p
    }

    /// The demo's report with these packages in place of its own.
    func report(_ packages: [Package]) async throws -> StatusReport {
        let store = AppStore(deps: Demo.dependencies(.arm64, pace: 0), settings: testSettings())
        await store.start()
        var r = try #require(store.report)
        r.packages = packages
        return r
    }

    @Test func offLeavesSelfUpdatingCasksToTheirApp() async throws {
        let rules = UpgradeRulesSettings(defaults: TestDefaults.fresh())
        let r = try await report([cask("google-chrome", autoUpdates: true), cask("firefox", autoUpdates: false)])
        let off = rules.decorate(r, includeSelfUpdating: false)
        let chrome = off.packages[0], firefox = off.packages[1]
        #expect(chrome.selfUpdateHeld == true)
        #expect(!chrome.isUpgradeTarget)
        #expect(chrome.isManualUpgradeTarget) // selected explicitly, it still upgrades
        #expect(firefox.isUpgradeTarget)

        let on = rules.decorate(r, includeSelfUpdating: true)
        #expect(on.packages[0].selfUpdateHeld == nil && on.packages[0].isUpgradeTarget)
    }

    @Test func homebrewUpdatesItWinsOverTheSetting() async throws {
        let rules = UpgradeRulesSettings(defaults: TestDefaults.fresh())
        let chrome = cask("google-chrome", autoUpdates: true)
        rules.setSelfUpdatePolicy(SelfUpdateRule.key(chrome), .homebrew)
        let d = rules.decorate(try await report([chrome]), includeSelfUpdating: false)
        #expect(d.packages[0].selfUpdateHeld == nil && d.packages[0].isUpgradeTarget)
    }

    @Test func theStoreLeavesThemOutOfUpgradeAllUntilTurnedOn() async throws {
        let settings = testSettings()
        let store = AppStore(deps: Demo.dependencies(.arm64, pace: 0), settings: settings)
        await store.start()
        #expect(!store.insights.settings.includeSelfUpdatingApps)
        let selfUpdating = store.packages.filter { $0.kind == .cask && $0.autoUpdates == true && $0.upgradeAvailable }
        try #require(!selfUpdating.isEmpty)
        #expect(store.upgradable.allSatisfy { !($0.kind == .cask && $0.autoUpdates == true) })
    }

    @Test func theSettingSaysWhatItDoes() {
        #expect(SettingsHelp.includeSelfUpdatingApps.contains("Off, Tankard leaves them to their own updater"))
    }
}
