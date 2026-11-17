import Foundation
import Testing
@testable import TankardCore
@testable import TankardAppModel

// v0.8, app side: Adopt Apps through demo mode (groups, default ticks, the
// ambiguous-cask pick, the confirmation, `brew install --cask --adopt`
// through the queue and History), and the per-app self-update choice
// (upgrade targets, auto-update's plan, --greedy, persistence).

@MainActor
struct V08AdoptAppTests {
    func openedDemo() async throws -> AppStore {
        let store = AppStore(deps: Demo.dependencies(.arm64, pace: 0))
        await store.start()
        store.openAdopt()
        #expect(store.toolSheet == .adopt)
        #expect(await waitUntil { store.adopt.phase == .ready })
        return store
    }

    @Test func demoScanGroups() async throws {
        let store = try await openedDemo()
        let a = store.adopt
        func names(_ g: AdoptGroup) -> [String] { a.rows(g).map(\.app.displayName) }
        #expect(names(.ready) == ["Firefox", "Hidden Bar", "LibreOffice", "Obsidian"])
        #expect(names(.needsUpdate) == ["GIMP", "Impactor"])
        #expect(names(.cantAdopt) == ["Inkscape", "KiCad", "zoom.us"])
        #expect(names(.noCask) == ["Acme Widgets"])
        // Skipped before matching: VS Code (the demo has its cask), Things (App Store), Safari (Apple).
        #expect(a.scan.skipped.managed.map(\.displayName) == ["Visual Studio Code"])
        #expect(a.scan.skipped.appStore.map(\.displayName) == ["Things"])
        #expect(a.scan.skipped.apple.map(\.displayName) == ["Safari"])
        #expect(a.skippedLine.contains("1 already from Homebrew"))
        // Default ticks: ready and not name-only.
        #expect(Set(a.plan.map(\.token)) == ["firefox", "hiddenbar", "libreoffice", "obsidian"])
        let im = try #require(a.rows(.needsUpdate).first { $0.app.displayName == "Impactor" })
        #expect(a.confidence(im) == .low)
        // Can't tick what isn't ready.
        a.setTicked(im, true)
        #expect(!a.isTicked(im))
    }

    @Test func ambiguousNameDefaultsToThePlainCaskAndCanBeChanged() async throws {
        let store = try await openedDemo()
        let a = store.adopt
        let ff = try #require(a.rows(.ready).first { $0.app.displayName == "Firefox" })
        #expect(ff.candidates == ["firefox", "firefox@beta"])
        #expect(a.token(ff) == "firefox")
        a.choose("firefox@beta", for: ff)
        #expect(a.token(ff) == "firefox@beta")
        // auto_updates: any version adopts, so still ready and ticked.
        #expect(a.group(ff) == .ready && a.isTicked(ff))
        #expect(a.plan.first { $0.appPath == ff.app.path }?.qualifiedName == "homebrew/cask/firefox@beta")
        a.choose("not-a-candidate", for: ff)
        #expect(a.token(ff) == "firefox@beta")
    }

    @Test func confirmRunsAdoptThroughTheQueueAndSavesTheChoice() async throws {
        let store = try await openedDemo()
        let a = store.adopt
        for r in a.rows(.ready) where r.app.displayName != "Obsidian" { a.setTicked(r, false) }
        let ob = try #require(a.rows(.ready).first { $0.app.displayName == "Obsidian" })
        a.setPolicy(.app, for: ob)
        a.requestAdopt()
        let items = try #require(a.pendingConfirm)
        #expect(items.map(\.token) == ["obsidian"])
        #expect(items[0].command == "brew install --cask --adopt homebrew/cask/obsidian")
        let text = AdoptStore.confirmationText(items)
        #expect(text.contains("downloads the cask"))
        #expect(text.contains("deletes the app"))
        store.confirmAdopt()
        #expect(a.pendingConfirm == nil)
        #expect(store.toolSheet == nil)
        #expect(await waitUntil { store.upgrade != nil })
        let session = try #require(store.upgrade)
        #expect(session.action == .adopt)
        #expect(session.items.map(\.command.arguments) == [["install", "--cask", "--adopt", "homebrew/cask/obsidian"]])
        #expect(await waitUntil { store.upgrade?.isFinished == true })
        #expect(session.succeededCount == 1)
        #expect(store.upgradeRules.selfUpdatePolicy("obsidian") == .app)
        #expect(await waitUntil { store.history.entries.contains { $0.arguments.contains("--adopt") } })
        #expect(store.history.entries.first { $0.arguments.contains("--adopt") }?.category == .install)
        // The refresh after the run lists the adopted cask.
        #expect(await waitUntil { store.packages.contains { $0.name == "obsidian" && $0.kind == .cask } })
        // A re-scan now counts it as Homebrew's.
        await a.load()
        #expect(a.scan.skipped.managed.map(\.displayName).contains("Obsidian"))
    }

    @Test func nothingRunsWithoutAConfirmation() async throws {
        let store = try await openedDemo()
        store.confirmAdopt()
        #expect(store.upgrade == nil)
        store.adopt.requestAdopt()
        store.adopt.cancelConfirm()
        store.confirmAdopt()
        #expect(store.upgrade == nil)
    }

    @Test func intelbrewModeSaysWhyItCantScan() async throws {
        // A real Intelbrew brew (no demo loader): no cask.json to read.
        var deps = Demo.dependencies(.intelbrew, pace: 0)
        deps.adoptLoader = nil
        let store = AppStore(deps: deps)
        await store.start()
        store.openAdopt()
        #expect(await waitUntil { if case .failed = store.adopt.phase { true } else { false } })
        if case .failed(let m) = store.adopt.phase { #expect(m.contains("formulae.brew.sh")) }
    }

    // MARK: self-updating apps

    func cask(_ name: String, autoUpdates: Bool = true, upgrade: Bool = true) -> Package {
        var p = Package.command(name)
        p.id = "cask:homebrew/cask/\(name)"
        p.kind = .cask
        p.autoUpdates = autoUpdates
        p.upgradeAvailable = upgrade
        p.installedVersion = "1.0"
        p.currentVersion = "2.0"
        p.appPaths = ["/Applications/\(name).app"]
        return p
    }

    @Test func selfUpdateRuleHoldsOnlySelfUpdatingCasks() {
        let tokens: Set<String> = ["obsidian", "plain"]
        #expect(SelfUpdateRule.leftToApp(cask("obsidian"), appTokens: tokens))
        #expect(!SelfUpdateRule.leftToApp(cask("plain", autoUpdates: false), appTokens: tokens))
        #expect(!SelfUpdateRule.leftToApp(cask("other"), appTokens: tokens))
        let snap = UpgradeRuleSnapshot(appUpdates: ["obsidian"])
        #expect(snap.skipReason(cask("obsidian")) == .appUpdatesItself)
        #expect(snap.skipReason(cask("firefox")) == nil)
        #expect(SelfUpdateRule.needsGreedy(includeSelfUpdating: false, packages: [cask("a")], homebrewTokens: []) == false)
        #expect(SelfUpdateRule.needsGreedy(includeSelfUpdating: false, packages: [cask("a")], homebrewTokens: ["a"]))
        #expect(SelfUpdateRule.needsGreedy(includeSelfUpdating: true, packages: [cask("a")], homebrewTokens: []))
        #expect(SelfUpdateRule.needsGreedy(includeSelfUpdating: true, packages: [], homebrewTokens: []) == false)
    }

    @Test func policyIsPersistedAndDecorates() throws {
        let defaults = try #require(UserDefaults(suiteName: "tankard-test-\(UUID().uuidString)"))
        let rules = UpgradeRulesSettings(defaults: defaults)
        var changes = 0
        rules.onPolicyChange = { changes += 1 }
        rules.setSelfUpdatePolicy("obsidian", .app)
        rules.setSelfUpdatePolicy("firefox", .homebrew)
        rules.setSelfUpdatePolicy("firefox", .homebrew) // unchanged: no write, no notice
        #expect(changes == 2)
        let again = UpgradeRulesSettings(defaults: defaults)
        #expect(again.selfUpdatePolicy("obsidian") == .app)
        #expect(again.selfUpdatePolicy("firefox") == .homebrew)
        #expect(again.selfUpdatePolicy("other") == .automatic)
        #expect(again.homebrewUpdatedTokens == ["firefox"] && again.appUpdatedTokens == ["obsidian"])
        again.setSelfUpdatePolicy("firefox", .automatic)
        #expect(again.selfUpdatePolicies["firefox"] == nil)

        let report = StatusReport(generatedAt: Date(), host: HostInfo(brewPath: "/opt/homebrew/bin/brew", prefix: "/opt/homebrew", repository: "/opt/homebrew",
                                                                      platform: BottlePlatform(arch: .arm64, macOSVersion: "27", cellar: "/opt/homebrew/Cellar"), bottleTag: "arm64_golden_gate"),
                                  intelbrew: IntelbrewDetection(detected: false, reasons: [], env: [:], found: [:]),
                                  fork: ForkStatus(brewRepository: "/opt/homebrew"),
                                  packages: [cask("obsidian"), cask("firefox")])
        let d = again.decorate(report)
        #expect(d.packages[0].selfUpdateHeld == true && !d.packages[0].isUpgradeTarget && d.packages[0].isManualUpgradeTarget)
        #expect(d.packages[1].selfUpdateHeld == nil && d.packages[1].isUpgradeTarget)
    }

    @Test func autoUpdatePlanSkipsAppUpdatedCasks() {
        let plan = AutoUpdateSafeMode.plan([cask("obsidian"), cask("firefox")], classifier: CompileClassifier(), running: [],
                                           dontQuitApps: true, rules: UpgradeRuleSnapshot(appUpdates: ["obsidian"]))
        #expect(plan.run.map(\.name) == ["firefox"])
        #expect(plan.skipped.map(\.package.name) == ["obsidian"])
        #expect(plan.skipped.first?.reason == .appUpdatesItself)
        #expect(AutoUpdateSkip.appUpdatesItself.text == "set to update itself")
    }

    @Test func homebrewChoiceKeepsGreedyUpgradeWithTheSettingOff() async throws {
        // The arm64 demo's greedy list adds tailscale-app (auto_updates).
        let store = AppStore(deps: Demo.dependencies(.arm64, pace: 0))
        await store.start()
        #expect(store.insights.settings.includeSelfUpdatingApps == false)
        let ts = { store.packages.first { $0.name == "tailscale-app" } }
        #expect(ts()?.upgradeAvailable == false)
        store.upgradeRules.setSelfUpdatePolicy("tailscale-app", .homebrew) // re-reads with --greedy
        #expect(await waitUntil { ts()?.upgradeAvailable == true })
        #expect(ts()?.selfUpdatingUpgrade == true && ts()?.isUpgradeTarget == true)
        #expect(store.upgradable.contains { $0.name == "tailscale-app" })
        // "App updates itself": still listed by brew, but not a target.
        store.upgradeRules.setSelfUpdatePolicy("tailscale-app", .app)
        #expect(await waitUntil { ts()?.selfUpdateHeld == true || ts()?.upgradeAvailable == false })
        #expect(!store.upgradable.contains { $0.name == "tailscale-app" })
    }

    @Test func adoptActionWords() {
        #expect(SessionAction.adopt.verb == "Adopt")
        #expect(BrewCommands.arguments(.adopt, for: AdoptPlanItem(token: "hiddenbar", qualifiedName: "homebrew/cask/hiddenbar",
                                                                    appPath: "/Applications/Hidden Bar.app", appVersion: "1.13.0",
                                                                    caskVersion: "1.13.0", autoUpdates: false, policy: .automatic).asPackage())
                == ["install", "--cask", "--adopt", "homebrew/cask/hiddenbar"])
        // Keep the previous version applies (an install can start brew's cleanup).
        #expect(RollbackSettings.appliesTo(.adopt))
        #expect(!AppManagement.modifiesApps(.adopt, Package.command("x")))
    }
}
