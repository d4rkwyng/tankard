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
        // 0.8.1: adopt gets the App Management explainer first (tested in V081AppManagementTests).
        store.settings.appManagementExplained = true
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
        #expect(store.upgradeRules.selfUpdatePolicy("homebrew/cask/obsidian") == .app)
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
        let tokens: Set<String> = ["homebrew/cask/obsidian", "homebrew/cask/plain"]
        #expect(SelfUpdateRule.leftToApp(cask("obsidian"), appTokens: tokens))
        #expect(!SelfUpdateRule.leftToApp(cask("plain", autoUpdates: false), appTokens: tokens))
        #expect(!SelfUpdateRule.leftToApp(cask("other"), appTokens: tokens))
        let snap = UpgradeRuleSnapshot(appUpdates: ["homebrew/cask/obsidian"])
        #expect(snap.skipReason(cask("obsidian")) == .appUpdatesItself)
        #expect(snap.skipReason(cask("firefox")) == nil)
        #expect(SelfUpdateRule.needsGreedy(includeSelfUpdating: false, packages: [cask("a")], homebrewTokens: []) == false)
        #expect(SelfUpdateRule.needsGreedy(includeSelfUpdating: false, packages: [cask("a")], homebrewTokens: ["homebrew/cask/a"]))
        #expect(SelfUpdateRule.needsGreedy(includeSelfUpdating: true, packages: [cask("a")], homebrewTokens: []))
        #expect(SelfUpdateRule.needsGreedy(includeSelfUpdating: true, packages: [], homebrewTokens: []) == false)
    }

    @Test func policyIsPersistedAndDecorates() throws {
        let defaults = TestDefaults.fresh("tankard-test-\(UUID().uuidString)")
        let rules = UpgradeRulesSettings(defaults: defaults)
        var changes = 0
        rules.onPolicyChange = { changes += 1 }
        rules.setSelfUpdatePolicy("homebrew/cask/obsidian", .app)
        rules.setSelfUpdatePolicy("firefox", .homebrew)
        rules.setSelfUpdatePolicy("firefox", .homebrew) // unchanged: no write, no notice
        #expect(changes == 2)
        let again = UpgradeRulesSettings(defaults: defaults)
        #expect(again.selfUpdatePolicy("homebrew/cask/obsidian") == .app)
        #expect(again.selfUpdatePolicy("firefox") == .homebrew)
        #expect(again.selfUpdatePolicy("other") == .automatic)
        #expect(again.homebrewUpdatedTokens == ["firefox"] && again.appUpdatedTokens == ["homebrew/cask/obsidian"])
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
                                           dontQuitApps: true, rules: UpgradeRuleSnapshot(appUpdates: ["homebrew/cask/obsidian"]))
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
        store.upgradeRules.setSelfUpdatePolicy("homebrew/cask/tailscale-app", .homebrew) // re-reads with --greedy
        #expect(await waitUntil { ts()?.upgradeAvailable == true })
        #expect(ts()?.selfUpdatingUpgrade == true && ts()?.isUpgradeTarget == true)
        #expect(store.upgradable.contains { $0.name == "tailscale-app" })
        // "App updates itself": still listed by brew, but not a target.
        store.upgradeRules.setSelfUpdatePolicy("homebrew/cask/tailscale-app", .app)
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
    // MARK: review: default ticks for self-updating casks

    /// A store on a hand-made index (no demo, no I/O).
    func adoptStore(_ casks: [AdoptCask], _ apps: [InstalledApp]) -> AdoptStore {
        let a = AdoptStore()
        a.apply(AdoptInput(index: AdoptIndex(casks: casks), apps: apps, source: "test"))
        return a
    }

    static func app(_ rel: String, _ bid: String, _ v: String) -> InstalledApp {
        InstalledApp(path: "/Applications/" + rel, root: "/Applications", relativePath: rel, bundleID: bid,
                     shortVersion: v, bundleVersion: v)
    }

    @Test func selfUpdatingCaskTicksOnlyASureMatch() throws {
        let target = [BrewInfoJSON.Cask.AdoptArtifacts.App(source: "Foo.app", target: "/Applications/Foo.app")]
        // The review's case: Alice's io.github.alice.Foo vs Bob's GitHub-hosted auto_updates cask "foo".
        let bobs = AdoptCask(token: "foo", version: "2.0", autoUpdates: true, web: "https://github.com/bob/foo", apps: target)
        var a = adoptStore([bobs], [Self.app("Foo.app", "io.github.alice.Foo", "1.0")])
        var row = try #require(a.scan.rows.first)
        #expect(a.group(row) == .ready && a.confidence(row) == .low)
        #expect(!a.isTicked(row) && a.plan.isEmpty)
        // Same vendor (owner alice) but not the exact bundle id: still not ticked for a self-updating cask.
        var alices = bobs
        alices.web = "https://github.com/alice/foo"
        a = adoptStore([alices], [Self.app("Foo.app", "io.github.alice.Foo", "1.0")])
        row = try #require(a.scan.rows.first)
        #expect(a.confidence(row) == .medium && !a.isTicked(row))
        // The user can still tick it by hand.
        a.setTicked(row, true)
        #expect(a.plan.map(\.token) == ["foo"])
        // The bundle id named by the cask: ticked.
        alices.bundleIDs = ["io.github.alice.foo"]
        a = adoptStore([alices], [Self.app("Foo.app", "io.github.alice.Foo", "1.0")])
        row = try #require(a.scan.rows.first)
        #expect(a.confidence(row) == .high && a.isTicked(row))
        // Not self-updating: a likely match at the same version is ticked (brew compares the download).
        var plain = AdoptCask(token: "foo", version: "1.0", web: "https://github.com/alice/foo", apps: target)
        a = adoptStore([plain], [Self.app("Foo.app", "io.github.alice.Foo", "1.0")])
        row = try #require(a.scan.rows.first)
        #expect(a.confidence(row) == .medium && a.isTicked(row))
        plain.web = "https://github.com/bob/foo"
        a = adoptStore([plain], [Self.app("Foo.app", "io.github.alice.Foo", "1.0")])
        row = try #require(a.scan.rows.first)
        #expect(a.confidence(row) == .low && !a.isTicked(row))
    }
    // MARK: review: the confirmation says what brew actually checks

    static func item(_ token: String, auto: Bool, _ conf: AdoptConfidence = .high) -> AdoptPlanItem {
        AdoptPlanItem(token: token, qualifiedName: "homebrew/cask/\(token)", appPath: "/Applications/\(token.capitalized).app",
                      appVersion: "1.0", caskVersion: "1.0", autoUpdates: auto, policy: .automatic, confidence: conf)
    }

    @Test func confirmationTextMatchesWhatBrewChecks() {
        let checked = AdoptStore.confirmationText([Self.item("gimp", auto: false)])
        #expect(checked.contains("checks the download against the app"))
        #expect(checked.contains("If a download doesn't match, brew stops"))
        #expect(!checked.contains("without a version check") && !checked.contains("Name only"))

        let auto = AdoptStore.confirmationText([Self.item("obsidian", auto: true)])
        #expect(!auto.contains("checks the download"))
        #expect(!auto.contains("doesn't match"))
        #expect(auto.contains("Adopted without a version check: Obsidian."))
        #expect(auto.contains("deletes the app"))

        let mixed = AdoptStore.confirmationText([Self.item("gimp", auto: false), Self.item("obsidian", auto: true)])
        #expect(!mixed.contains("checks the download against the app that is there, and then"))
        #expect(mixed.contains("Adopted without a version check: Obsidian."))
        #expect(mixed.contains("The other apps are checked"))

        // A name-only row the user ticked by hand: warned, first.
        let low = AdoptStore.confirmationText([Self.item("foo", auto: true, .low), Self.item("gimp", auto: false, .medium)])
        #expect(low.hasPrefix("Name only: Foo."))
        #expect(!low.contains("Gimp. Nothing"))
    }

    @Test func confirmationCarriesTheRowsConfidence() throws {
        let target = [BrewInfoJSON.Cask.AdoptArtifacts.App(source: "Foo.app", target: "/Applications/Foo.app")]
        let bobs = AdoptCask(token: "foo", version: "2.0", autoUpdates: true, web: "https://github.com/bob/foo", apps: target)
        let a = adoptStore([bobs], [Self.app("Foo.app", "io.github.alice.Foo", "1.0")])
        let row = try #require(a.scan.rows.first)
        a.setTicked(row, true)
        a.requestAdopt()
        let items = try #require(a.pendingConfirm)
        #expect(items.map(\.confidence) == [.low])
        #expect(AdoptStore.confirmationText(items).hasPrefix("Name only: Foo."))
    }
    // MARK: review: small items

    @Test func confirmationListsEveryCommand() {
        let items = [Self.item("gimp", auto: false), Self.item("obsidian", auto: true)]
        let text = AdoptStore.commandsText(items)
        #expect(text.contains("brew install --cask --adopt homebrew/cask/gimp\nbrew install --cask --adopt homebrew/cask/obsidian"))
        #expect(!text.contains("<cask>") && !text.contains("one per app"))
        #expect(AdoptStore.commandsText([items[0]]) == "brew install --cask --adopt homebrew/cask/gimp")
        let many = (1...10).map { Self.item("c\($0)", auto: false) }
        let t = AdoptStore.commandsText(many)
        #expect(t.contains("homebrew/cask/c8") && !t.contains("homebrew/cask/c9") && t.contains("and 2 more"))
    }

    @Test func selfUpdateChoiceIsSavedOnlyWhenTheAdoptSucceeds() async throws {
        let store = try await openedDemo()
        // The demo's brew has no such cask: the adopt fails.
        let bad = AdoptPlanItem(token: "no-such-cask", qualifiedName: "homebrew/cask/no-such-cask", appPath: "/Applications/Nope.app",
                                appVersion: "1.0", caskVersion: "1.0", autoUpdates: true, policy: .app)
        #expect(store.startAdopt([bad]))
        // Not saved before the run.
        #expect(store.upgradeRules.selfUpdatePolicy("homebrew/cask/no-such-cask") == .automatic)
        #expect(await waitUntil { store.upgrade?.isFinished == true })
        #expect(store.upgrade?.failedItems.count == 1)
        #expect(store.upgradeRules.selfUpdatePolicy("homebrew/cask/no-such-cask") == .automatic)
    }

    @Test func uninstallTooltipMatchesTheSheet() {
        var p = Package.command("luarocks"); p.kind = .formula
        var lua = Package.command("lua"); lua.kind = .formula
        let one = AppStore.uninstallDisplay(p)
        #expect(one.contains("HOMEBREW_NO_AUTOREMOVE=1") && one.contains("brew uninstall") && one.hasSuffix("luarocks"))
        let lines = AppStore.uninstallDisplay(p, orphans: [lua]).split(separator: "\n")
        #expect(lines.count == 2 && lines.allSatisfy { $0.contains("HOMEBREW_NO_AUTOREMOVE=1") } && lines[1].hasSuffix("lua"))
    }
    // MARK: QA: self-update choices are per qualified cask and leave with it

    @Test func selfUpdateChoiceIsPerTapAndClearedOnUninstall() async throws {
        let store = try await openedDemo()
        let ob = try #require(store.packages.first { $0.kind == .cask && $0.autoUpdates == true })
        var other = ob
        other.id = "cask:someone/tap/\(ob.name)"
        other.tap = "someone/tap"
        other.fullName = "someone/tap/\(ob.name)"
        store.setSelfUpdatePolicy(ob, .app)
        #expect(store.selfUpdatePolicy(ob) == .app)
        #expect(store.selfUpdatePolicy(other) == .automatic)
        #expect(store.upgradeRules.selfUpdatePolicies.keys.contains(SelfUpdateRule.key(ob)))
        #expect(!SelfUpdateRule.leftToApp(other, appTokens: store.upgradeRules.appUpdatedTokens))
        // Uninstalling the cask removes its choice.
        store.closeToolSheet()
        store.settings.appManagementExplained = true // no first-use explainer in between
        store.requestUninstall(ob)
        store.startUninstall(ob)
        #expect(await waitUntil { store.upgrade?.isFinished == true })
        #expect(store.upgrade?.succeededCount == 1)
        #expect(store.upgradeRules.selfUpdatePolicies[SelfUpdateRule.key(ob)] == nil)
    }
    /// QA: something takes brew in the 450 ms between the confirmation
    /// and the run: the status bar says the adopt didn't start.
    @Test func adoptThatCantStartSaysSo() async throws {
        var deps = Demo.dependencies(.arm64, pace: 0)
        let demoRunner = deps.streamRunner
        let latch = Latch()
        deps.streamRunner = FakeStreamRunner(log: CallLog()) { args, out in
            if args.first == "upgrade" { await latch.wait(); return 0 }
            return try await demoRunner.stream("/opt/homebrew/bin/brew", args, environment: [:], output: out)
        }
        let store = AppStore(deps: deps)
        await store.start()
        store.openAdopt()
        #expect(await waitUntil { store.adopt.phase == .ready })
        let target = try #require(store.upgradable.first { $0.kind == .formula })
        store.adopt.requestAdopt()
        #expect(store.adopt.pendingConfirm != nil)
        store.confirmAdopt()
        store.startUpgrade([target])
        #expect(store.upgrade?.action == .upgrade)
        #expect(await waitUntil { store.busyNotice != nil })
        #expect(store.busyNotice?.contains("didn't start: an upgrade is still running") == true)
        #expect(store.upgrade?.action == .upgrade)
        latch.release()
    }
    @Test func replaceCommandOnlyForASureMatch() async throws {
        let store = try await openedDemo()
        let a = store.adopt
        let im = try #require(a.rows(.needsUpdate).first { $0.app.displayName == "Impactor" })
        #expect(a.confidence(im) == .low && !a.offersReplace(im))
        let gimp = try #require(a.rows(.needsUpdate).first { $0.app.displayName == "GIMP" })
        #expect(a.offersReplace(gimp) == (a.confidence(gimp) == .high))
        // Never outside "Needs update first".
        #expect(a.rows(.ready).allSatisfy { !a.offersReplace($0) })
    }
    /// QA: a cask with two apps is two rows but one adopt.
    @Test func twoAppsOfOneCaskAdoptOnce() throws {
        let apps = [BrewInfoJSON.Cask.AdoptArtifacts.App(source: "Foo.app", target: "/Applications/Foo.app"),
                    BrewInfoJSON.Cask.AdoptArtifacts.App(source: "Foo Helper.app", target: "/Applications/Foo Helper.app")]
        let c = AdoptCask(token: "foo", version: "1.0", apps: apps, bundleIDs: ["com.foo.foo", "com.foo.helper"])
        let a = adoptStore([c], [Self.app("Foo.app", "com.foo.foo", "1.0"), Self.app("Foo Helper.app", "com.foo.helper", "1.0")])
        #expect(a.rows(.ready).count == 2 && a.rows(.ready).allSatisfy(a.isTicked))
        #expect(a.plan.map(\.token) == ["foo"])
        a.requestAdopt()
        #expect(a.pendingConfirm?.count == 1)
        #expect(AdoptStore.commandsText(a.pendingConfirm ?? []) == "brew install --cask --adopt homebrew/cask/foo")
    }
}
