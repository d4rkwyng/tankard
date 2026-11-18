import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.5 final pass: the Upgrades filter's "skip what would build" button
// goes through the plan like every other Upgrade button (F1).

@MainActor
struct V085SkipCompilesPlanTests {
    static let chrome = RunningApp(path: "/Applications/Google Chrome.app", bundleID: "com.google.Chrome")

    func rig(_ variant: Demo.Variant, running: [RunningApp] = [chrome]) async -> AppStore {
        var deps = Demo.dependencies(variant, pace: 0)
        deps.appManagementGate = false
        deps.askpassHelper = AdminPasswordTests.helper
        deps.streamRunner = FakeStreamRunner(log: CallLog()) { _, _ in 0 }
        let settings = testSettings()
        InsightSettings(defaults: settings.defaults).includeSelfUpdatingApps = true // 0.8.6 (M5): Chrome (auto_updates) in Upgrade All
        let store = AppStore(deps: deps, settings: settings)
        store.autoUpdate.conditions = FixedConditions(ac: nil, idle: nil, apps: running)
        await store.start()
        // One formula upgrade has no bottle here, so it would compile.
        var r = store.report!
        if let i = r.packages.firstIndex(where: { $0.kind == .formula && $0.isManualUpgradeTarget }) {
            r.packages[i].upgradeHasBottle = false
        }
        store.report = r
        return store
    }

    /// F1: the button opens the plan with the compiling ones already
    /// skipped, so the open-apps note, the password lock and order, and the
    /// compile rows show before anything starts.
    @Test func filterButtonOpensThePlanWithCompilesSkipped() async throws {
        let store = await rig(.arm64)
        store.demoRequirePassword("google-chrome")
        let (bottled, compiling) = store.deps.classifier.partitionUpgrades(store.upgradable)
        try #require(!compiling.isEmpty && bottled.contains { $0.name == "google-chrome" })

        store.startUpgradeSkippingCompiles()
        let plan = try #require(store.upgradePlan)
        #expect(store.upgrade == nil)  // nothing started yet
        #expect(store.showUpgradeSheet)
        #expect(plan.skipCompiling)
        // Every upgrade is listed; what compiles is shown as skipped.
        #expect(Set(plan.rows.map(\.package.id)) == Set(store.upgradable.map(\.id)))
        #expect(Set(plan.toRun.map(\.id)) == Set(bottled.map(\.id)))
        #expect(plan.compiling.map(\.id).sorted() == compiling.map(\.id).sorted())
        #expect(plan.runningAppsNote?.contains("Google Chrome") == true)
        #expect(plan.needingPassword.map(\.name) == ["google-chrome"])
        #expect(plan.rows.last?.package.name == "google-chrome")
        #expect(plan.startTitle == "Upgrade \(bottled.count) (skip \(compiling.count))")

        store.confirmUpgradePlan()
        let session = try #require(store.upgrade)
        #expect(Set(session.items.map(\.package.id)) == Set(bottled.map(\.id)))
    }

    /// Not over the progress panel's plan or result (same gate as Upgrade).
    @Test func refusedWhileThePanelHoldsTheActivity() async throws {
        let store = await rig(.arm64, running: [])
        _ = store.requestUpgradeFromMenuBar(nil, windowInFront: false)
        let panelPlan = try #require(store.upgradePlan)
        store.startUpgradeSkippingCompiles()
        #expect(store.upgradePlan?.id == panelPlan.id)
        #expect(store.upgrade == nil)
    }

    /// The button's words: casks are included and nothing says "bottles".
    @Test func buttonTitleSaysWhatItSkips() async throws {
        let store = await rig(.arm64, running: [])
        let button = try #require(store.skipCompilesButton)
        let (bottled, compiling) = store.deps.classifier.partitionUpgrades(store.upgradable)
        #expect(bottled.contains { $0.kind == .cask })
        #expect(button.count == bottled.count)
        #expect(button.title == "Upgrade \(bottled.count) without building from source")
        #expect(!button.title.contains("bottle"))
        #expect(button.help.contains(compiling[0].name))
    }
}

// L1: the Restore Points "Keep Old Versions" banner is advice, so it uses
// the neutral info look (like Health's "Usually harmless" cards), not the
// vulnerability warning colour. A view can't be inspected from here, so
// this reads the banner's source.
struct V085KeepOldVersionsBannerToneTests {
    static func bannerSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/TankardApp/RestorePointsViews.swift"), encoding: .utf8)
        let start = try #require(src.range(of: "if points.showsKeepOldVersionsBanner {"))
        let end = try #require(src.range(of: "Button(\"Keep Old Versions\")", range: start.upperBound..<src.endIndex))
        return String(src[start.lowerBound..<end.lowerBound])
    }

    @Test func bannerIconIsNeutralInfo() throws {
        let banner = try Self.bannerSource()
        #expect(banner.contains("Image(systemName: \"info.circle\")"))
        #expect(banner.contains(".foregroundStyle(.secondary)"))
        #expect(!banner.contains("warning("))
        #expect(!banner.contains(".red"))
    }
}

// L2: the password box says what happens in plain words; brew, sudo and
// Terminal go under Details.
struct V085PasswordNoteWordingTests {
    @Test func plainWordsUpFrontTechnicalUnderDetails() {
        for helper in [true, false] {
            for uninstall in [true, false] {
                let note = AdminPassword.noteText(helper: helper, uninstall: uninstall)
                for word in ["brew", "sudo", "Terminal", "SUDO_ASKPASS"] {
                    #expect(!note.plain.contains(word), "\(helper) \(uninstall): \(note.plain)")
                }
                #expect(note.details.contains("sudo"))
            }
        }
        #expect(AdminPassword.noteText(helper: true, uninstall: false).plain
                == "Tankard will ask for it in a dialog when the upgrade gets there. It never stores it.")
        #expect(AdminPassword.noteText(helper: true, uninstall: true).plain
                == "Tankard will ask for it in a dialog while removing it. It never stores it.")
        #expect(AdminPassword.noteText(helper: false, uninstall: false).details.contains("Terminal"))
    }
}
