import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.5: the newbie walkthrough's High items (scratch review H1-H5) and
// related plain-language fixes.

@MainActor
struct V085RunningAppsTests {
    func rig(running: [RunningApp]) async -> AppStore {
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.appManagementGate = false
        deps.streamRunner = FakeStreamRunner(log: CallLog()) { _, _ in 0 }
        let store = AppStore(deps: deps, settings: testSettings())
        store.autoUpdate.conditions = FixedConditions(ac: nil, idle: nil, apps: running)
        await store.start()
        return store
    }

    static let chrome = RunningApp(path: "/Applications/Google Chrome.app", bundleID: "com.google.Chrome")

    func chromeCask(_ store: AppStore) throws -> Package {
        try #require(store.packages.first { $0.name == "google-chrome" && $0.isManualUpgradeTarget })
    }

    /// H2: upgrading a cask whose app is open asks first, naming the app.
    @Test func openAppAsksBeforeUpgrading() async throws {
        let store = await rig(running: [Self.chrome])
        let chrome = try chromeCask(store)
        store.requestUpgrade([chrome])
        let plan = try #require(store.upgradePlan)
        #expect(store.upgrade == nil)  // nothing started yet
        #expect(plan.runningAppsToRun == ["Google Chrome"])
        #expect(plan.runningAppsNote?.contains("Google Chrome") == true)
        store.cancelUpgradePlan()
        #expect(store.upgrade == nil)
    }

    /// By bundle id alone (an app moved out of /Applications).
    @Test func matchesByBundleID() async throws {
        let store = await rig(running: [RunningApp(path: "/Users/x/Apps/Google Chrome.app", bundleID: "com.google.Chrome")])
        store.requestUpgrade([try chromeCask(store)])
        #expect(store.upgradePlan?.runningAppsToRun == ["Google Chrome"])
    }

    /// The menu-bar panel's Upgrade All asks the same way, in the panel.
    @Test func menuBarUpgradeAllAsksToo() async throws {
        let store = await rig(running: [Self.chrome])
        _ = try chromeCask(store)
        let shown = store.requestUpgradeFromMenuBar(nil, windowInFront: false)
        #expect(shown == .progressPanel)
        let plan = try #require(store.upgradePlan)
        #expect(plan.runningAppsToRun == ["Google Chrome"])
    }

    /// Nothing open, or only formulae: no extra question.
    @Test func noPromptWhenNothingIsOpenOrFormulaOnly() async throws {
        let none = await rig(running: [])
        let chrome = try chromeCask(none)
        #expect(none.runningCaskApps([chrome]).isEmpty)
        var plan = UpgradePlan(packages: [chrome], classifier: none.deps.classifier)
        plan.runningApps = none.runningCaskApps([chrome])
        #expect(plan.runningAppsNote == nil)

        let open = await rig(running: [Self.chrome])
        let formulae = open.packages.filter { $0.kind == .formula && $0.isManualUpgradeTarget }
        try #require(!formulae.isEmpty)
        #expect(open.runningCaskApps(formulae).isEmpty)
    }

    /// "Don't quit running apps during upgrades" on: brew leaves them
    /// running, so there is nothing to warn about.
    @Test func dontQuitSettingSkipsTheWarning() async throws {
        let store = await rig(running: [Self.chrome])
        store.insights.settings.dontQuitAppsDuringUpgrade = true
        #expect(store.runningCaskApps([try chromeCask(store)]).isEmpty)
    }
}

@MainActor
struct V085AutoremoveKeepTests {
    /// H3: untick one to keep it: `brew tab --installed-on-request` for it
    /// first (brew's own "keep"), then `brew autoremove`.
    @Test func untickedFormulaIsMarkedInstalledOnRequestFirst() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0))
        await store.start()
        store.openAutoremove()
        let a = try #require(store.autoremove)
        #expect(await waitUntil { a.phase == .ready })
        a.setKeep("libyaml", true)
        #expect(a.toRemove == ["icu4c@78", "homebrew/core/m4"])
        #expect(a.toKeep == ["libyaml"])
        store.startAutoremove()
        let items = try #require(store.upgrade?.items)
        #expect(items.map(\.command.arguments) == [
            ["tab", "--installed-on-request", "--formula", "libyaml"],
            ["autoremove"],
        ])
        #expect(await waitUntil { store.history.entries.contains { $0.arguments == ["autoremove"] && $0.outcome == .succeeded } })
    }

    @Test func keepingEverythingRemovesNothing() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0))
        await store.start()
        store.openAutoremove()
        let a = try #require(store.autoremove)
        #expect(await waitUntil { a.phase == .ready })
        for n in a.plan?.formulae ?? [] { a.setKeep(n, true) }
        #expect(a.toRemove.isEmpty)
        store.startAutoremove()
        #expect(store.upgrade == nil)
    }

    @Test func flagsFormulaePeopleUseDirectly() {
        #expect(AutoremovePlan.oftenUsedDirectly("python@3.14"))
        #expect(AutoremovePlan.oftenUsedDirectly("homebrew/core/node"))
        #expect(!AutoremovePlan.oftenUsedDirectly("homebrew/core/m4"))
        #expect(!AutoremovePlan.oftenUsedDirectly("libyaml"))
    }
}

/// H5: harmless doctor notes are information, not alarms; Clean Up and
/// Software Update are buttons, not commands.
struct V085DoctorTests {
    @Test func harmlessNotesAndActions() {
        let text = """
        Warning: Unbrewed dylibs were found in /usr/local/lib.
          /usr/local/lib/libfoo.dylib

        Warning: Broken symlinks were found. Remove them with `brew cleanup`:
          /opt/homebrew/bin/x

        Warning: A newer Command Line Tools release is available.
        Update them from Software Update in System Settings.

        Warning: Something brand new that Tankard has never seen
        """
        let r = DoctorReport.parse(text)
        #expect(r.warnings.count == 4)
        #expect(r.warnings.map(\.isHarmless) == [true, true, true, false])  // unknown: not "harmless", shown yellow
        #expect(r.warnings[1].action == .cleanUp)
        #expect(r.warnings[2].action == .softwareUpdate)
        #expect(r.warnings[0].action == nil && r.warnings[3].action == nil)
        #expect(DoctorWarningKind.notWritable.isHarmless == false)
    }
}

/// M4: uninstalling an app says what happens to the app and its settings.
@MainActor
struct V085CaskUninstallWordsTests {
    @Test func caskUninstallNamesTheAppAndKeepsSettings() async throws {
        let store = AppStore(deps: Demo.dependencies(.arm64, pace: 0), settings: testSettings())
        await store.start()
        let chrome = try #require(store.packages.first { $0.name == "google-chrome" })
        #expect(AppStore.uninstallSummary(chrome, dependenciesStay: true)
                == "Deletes Google Chrome from Applications. Your settings and data for it stay on this Mac.")
        var bare = chrome
        bare.appPaths = nil
        #expect(!AppStore.uninstallSummary(bare, dependenciesStay: true).contains("dependencies"))
    }
}
