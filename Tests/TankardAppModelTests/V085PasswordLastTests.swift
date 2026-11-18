import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.5: casks that ask for the administrator password run last in an
// upgrade (their dialogs come at the end, not in the middle of the run),
// keeping what depends on them after them; an automatic run's
// "needs your administrator password" skip offers Upgrade Now.
@MainActor
struct V085PasswordLastTests {
    func cask(_ name: String, password: Bool = false, dependsOn: [String] = []) -> Package {
        var p = pkg(name, kind: .cask, apps: [], quit: [])
        p.installsPkg = password
        p.caskDependencies = dependsOn
        return p
    }

    @Test func passwordCasksGoLastInOrder() {
        let list = [pkg("a"), cask("word", password: true), cask("chrome"), pkg("b"), cask("teams", password: true), cask("zoom")]
        #expect(AdminPassword.passwordStepsLast(list).map(\.name) == ["a", "chrome", "b", "zoom", "word", "teams"])
        // A sudo installer script counts too.
        var vpn = cask("vpn")
        vpn.sudoInstaller = true
        #expect(AdminPassword.passwordStepsLast([vpn, pkg("a")]).map(\.name) == ["a", "vpn"])
        // Nothing needs the password: the order is untouched.
        let plain = [cask("z"), pkg("a"), cask("b")]
        #expect(AdminPassword.passwordStepsLast(plain) == plain)
    }

    /// A cask that depends on a password cask moves to the end too (also
    /// through a chain), so nothing is moved ahead of what it needs.
    @Test func dependentsOfPasswordCasksFollowThem() {
        let list = [cask("plugin", dependsOn: ["homebrew/cask/driver"]), cask("driver", password: true),
                    cask("addon", dependsOn: ["plugin"]), cask("other"), pkg("f")]
        let out = AdminPassword.passwordStepsLast(list).map(\.name)
        #expect(out == ["other", "f", "plugin", "driver", "addon"])
        // The moved group keeps the input's relative order.
        let ordered = [cask("driver", password: true), cask("plugin", dependsOn: ["driver"]), cask("other")]
        #expect(AdminPassword.passwordStepsLast(ordered).map(\.name) == ["other", "driver", "plugin"])
    }

    func store() async -> AppStore {
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.appManagementGate = false
        deps.askpassHelper = AdminPasswordTests.helper
        let settings = testSettings()
        InsightSettings(defaults: settings.defaults).includeSelfUpdatingApps = true // 0.8.6 (M5): Chrome (auto_updates) in Upgrade All
        let store = AppStore(deps: deps, settings: settings)
        await store.start()
        return store
    }

    @Test func upgradeAllRunsThePasswordCaskLast() async throws {
        let store = await store()
        store.demoRequirePassword("google-chrome")
        let all = store.upgradable
        #expect(all.contains { $0.name == "google-chrome" } && all.last?.name != "google-chrome")
        // The plan lists the run's order.
        store.requestUpgrade()
        let plan = try #require(store.upgradePlan)
        #expect(plan.rows.last?.package.name == "google-chrome")
        #expect(plan.rows.count == all.count)
        store.confirmUpgradePlan()
        let s = try #require(store.upgrade)
        #expect(s.items.map(\.package.name).last == "google-chrome")
        #expect(Set(s.items.map(\.package.id)) == Set(all.map(\.id)))
        await #expect(waitUntil { s.isFinished })
    }

    @Test func autoUpdateLogOffersUpgradeNow() async throws {
        let store = await store()
        store.demoRequirePassword("google-chrome")
        store.autoUpdate.calendar = utc
        store.autoUpdate.settings.enabled = true
        // A dry run plans without brew update (which would reload the list
        // and drop the demo's password flag).
        store.autoUpdate.settings.dryRun = true
        let run = try #require(await store.autoUpdate.run(store: store, notifier: FakeNotifier()))
        #expect(run.passwordSkipped == ["google-chrome"])
        let item = try #require(run.skipped.first { $0.name == "google-chrome" })
        #expect(item.needsPassword == true && item.detail == AutoUpdateSkip.needsPassword.text)
        #expect(run.skipped.filter { $0.name != "google-chrome" }.allSatisfy { $0.needsPassword == nil })
        let targets = store.passwordSkippedUpgrades(run)
        #expect(targets.map(\.name) == ["google-chrome"])

        var closed = false
        store.showAutoUpdateLog = true
        store.upgradePasswordSkipped(run) { closed = true }
        #expect(closed && !store.showAutoUpdateLog)
        // A normal upgrade: the plan (it says the password will be asked).
        await #expect(waitUntil { store.upgradePlan != nil })
        #expect(store.upgradePlan?.rows.map(\.package.name) == ["google-chrome"])
        #expect(store.upgradePlan?.needingPassword.map(\.name) == ["google-chrome"])
    }

    @Test func nothingToOfferOnceUpgradedOrForOldLogs() async throws {
        let store = await store()
        // A log entry from before 0.8.5 (no flag) offers nothing.
        let old = AutoUpdateRun(startedAt: Date(), skipped: [.init(name: "google-chrome", isCask: true,
                                                                   detail: AutoUpdateSkip.needsPassword.text)])
        #expect(old.passwordSkipped.isEmpty && store.passwordSkippedUpgrades(old).isEmpty)
        // A flagged cask that no longer has an upgrade offers nothing.
        let gone = AutoUpdateRun(startedAt: Date(), skipped: [.init(name: "not-installed", isCask: true, detail: "x", needsPassword: true)])
        #expect(store.passwordSkippedUpgrades(gone).isEmpty)
        // Old JSON (no needsPassword key) still decodes.
        let json = #"{"name":"x","isCask":true,"detail":"d"}"#
        let item = try JSONDecoder().decode(AutoUpdateRun.Item.self, from: Data(json.utf8))
        #expect(item.needsPassword == nil)
    }
}
