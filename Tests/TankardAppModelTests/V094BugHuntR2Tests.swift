import Foundation
import Testing
@testable import TankardCore
@testable import TankardAppModel

// 0.9.4 bug hunt, round 2: user-facing bugs found against fake Homebrew.

func v094Source(_ file: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent("Sources/\(file)"), encoding: .utf8)
}

// MARK: Discover's detail-pane Install waits for brew info

// The row menu's Install reads "Install (checking…)" and is off until
// `brew info` details are in (whether it compiles isn't known before). The
// detail pane's button didn't wait: in Intelbrew mode a formula with no
// bottle block (bottle .unknown, no compile warning yet) read "Install foo"
// while "Asking brew info…" showed, and started a source build at once,
// skipping the "Install (compiles)" confirmation.
struct V094DiscoverInstallWaitsTests {
    static func entry(loaded: Bool) -> CatalogEntry {
        CatalogEntry(kind: .formula, name: "foo", fullName: "foo", tap: "homebrew/core", desc: nil, bottle: .unknown, detailsLoaded: loaded)
    }

    @Test func beforeDetailsItWaits() {
        let item = ContextMenus.discoverInstall(Self.entry(loaded: false), compileWarning: nil, busy: false)
        #expect(!item.isEnabled)
        #expect(item.title == "Install (checking…)")
    }

    @Test func afterDetailsItInstalls() {
        let item = ContextMenus.discoverInstall(Self.entry(loaded: true), compileWarning: nil, busy: false)
        #expect(item.isEnabled)
        #expect(item.action == .install(confirmCompile: false))
        #expect(!ContextMenus.discoverInstall(Self.entry(loaded: true), compileWarning: nil, busy: true).isEnabled)
    }

    /// The row menu and the detail pane share the rule.
    @Test func theDetailPaneUsesIt() throws {
        let menu = ContextMenus.discover(Self.entry(loaded: false), installed: false, compileWarning: nil, busy: false)
        #expect(menu.contains { if case .item(let m) = $0 { return m.id == "install" && !m.isEnabled }; return false })
        let view = try v094Source("TankardApp/DiscoverView.swift")
        #expect(view.contains("ContextMenus.discoverInstall(e, compileWarning: store.deps.classifier.installWarning(e)"))
        #expect(view.contains(".disabled(!install.isEnabled)"))
        #expect(!view.contains(".disabled(store.windowBrewActionsBlocked || e.disabled)"))
    }
}

// MARK: a pasted homebrew/core/… or homebrew/cask/… name finds it

// Tankard's own Copy Install Command gives `brew install --formula
// homebrew/core/wget` / `brew install --cask homebrew/cask/firefox`.
// Pasted into Discover it found nothing: the official taps' entries carry
// the short name as their full name.
struct V094QualifiedSearchTests {
    static let entries = [
        CatalogEntry(kind: .formula, name: "wget", fullName: "wget", tap: "homebrew/core", desc: "Internet file retriever", bottle: .forThisMac),
        CatalogEntry(kind: .cask, name: "firefox", fullName: "firefox", tap: "homebrew/cask", desc: "Web browser", bottle: .cask),
        CatalogEntry(kind: .formula, name: "probe", fullName: "walktest/probe/probe", tap: "walktest/probe", desc: nil, bottle: .forThisMac),
    ]

    @Test func officialTapNamesFindTheShortName() {
        #expect(CatalogSearch.search("homebrew/core/wget", in: Self.entries).map(\.name) == ["wget"])
        #expect(CatalogSearch.search("brew install --cask homebrew/cask/firefox", in: Self.entries).map(\.name) == ["firefox"])
        #expect(CatalogSearch.search("Homebrew/Core/WGET", in: Self.entries).map(\.name) == ["wget"])
    }

    @Test func tankardsOwnInstallCommandRoundTrips() {
        for e in Self.entries {
            #expect(CatalogSearch.search(e.installDisplay, in: Self.entries).first?.id == e.id, "\(e.installDisplay)")
        }
    }

    @Test func otherTapsAndPlainWordsAreUnchanged() {
        #expect(CatalogSearch.search("walktest/probe/probe", in: Self.entries).map(\.name) == ["probe"])
        #expect(CatalogSearch.search("homebrew/core/", in: Self.entries).isEmpty)
        #expect(CatalogSearch.officialShortName("homebrew/core/a/b") == "homebrew/core/a/b")
        #expect(CatalogSearch.officialShortName("wget") == "wget")
    }
}

// MARK: Discover's header and empty state name the searched term

// Spaces alone in the search field said "0 results for “”" (the table
// said "Search Homebrew"). A pasted command with no match said "Nothing
// matches “brew install --cask foo”" under "0 results for “foo”".
@MainActor
struct V094DiscoverTermTests {
    func store() async -> DiscoverStore {
        let d = DiscoverStore(provider: FixedAPICatalog(entries: V094QualifiedSearchTests.entries), debounce: .zero)
        await d.activate()
        return d
    }

    @Test func spacesSearchNothing() async {
        let d = await store()
        #expect(d.searchedNothing)
        d.query = "   "
        await d.searchNow()
        #expect(d.results.isEmpty)
        #expect(d.searchedNothing)
        d.query = "wget"
        await d.searchNow()
        #expect(!d.searchedNothing)
    }

    @Test func noMatchesNamesThePackage() async throws {
        let d = await store()
        d.query = "brew install --cask nothere"
        await d.searchNow()
        #expect(d.results.isEmpty)
        #expect(d.queryTerm == "nothere")
        #expect(d.noMatchesDetail(d.queryTerm).contains("“nothere”"))
        let view = try v094Source("TankardApp/DiscoverView.swift")
        #expect(view.contains("discover.noMatchesDetail(discover.queryTerm)"))
        #expect(view.contains("CasksBanner.noMatchesDetail(discover.queryTerm)"))
        #expect(view.contains("if discover.searchedNothing {"))
    }
}

// MARK: the Taps sheet's Trust reads the status again

// Trust Tap… from a package's "can't be read" box runs `brew trust --tap`
// and reads the status again. The Taps sheet's own Trust… / Stop Trusting
// re-read only the Taps list: a package from that tap stayed "can't be
// read" (and Remove blocked) until the next Refresh.
@MainActor
struct V094TapsTrustRereadsTests {
    @Test func trustFromTheSheetReadsTheStatus() async throws {
        let store = AppStore(deps: Demo.dependencies(.arm64, pace: 0))
        await store.start()
        store.openTaps()
        #expect(await waitUntil { store.taps.phase == .ready })
        let mull = try #require(store.taps.taps.first { $0.name == "mull-project/mull" })
        let reads = store.refreshesCompleted
        store.taps.requestTrust(mull)
        store.confirmTrustTap()
        #expect(await waitUntil { store.taps.taps.first { $0.name == "mull-project/mull" }?.trusted == true })
        #expect(await waitUntil { store.refreshesCompleted > reads })
        #expect(store.error == nil)
    }
}

// MARK: a service's action problem stays with that service

// The pane's problem line (unbound runs as root: restart needs sudo, with
// the sudo command) was cleared only by the next action, so selecting
// redis showed unbound's problem and its sudo command under redis's own
// Start / Stop buttons.
@MainActor
struct V094ServiceErrorScopeTests {
    @Test func selectingAnotherServiceClearsTheProblem() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0))
        await store.start()
        let services = try #require(store.openServices())
        await services.load()
        let unbound = try #require(services.services.first { $0.name == "unbound" })
        let redis = try #require(services.services.first { $0.name == "redis" })
        services.selection = unbound.id
        await services.perform(.restart, on: unbound, store: store)
        #expect(services.actionError?.terminalCommand == "sudo brew services restart unbound")
        services.selection = unbound.id // the same one: stays
        #expect(services.actionError != nil)
        services.selection = redis.id
        #expect(services.actionError == nil)
    }
}

// MARK: Services or Discover chosen before the first read

// ⌘3 (Services) during the first "Reading installed packages…" showed
// "Discover needs Homebrew's status first" on the Services tab, and stayed:
// the tab's store was made only on a tab change. The view now makes it
// once the status is in, and names the tab it is on.
@MainActor
struct V094TabBeforeStatusTests {
    @Test func theTabsStoreNeedsTheStatus() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0))
        #expect(store.openServices() == nil)
        await store.start()
        #expect(store.openServices() != nil)
    }

    @Test func theViewOpensItOnceTheStatusIsIn() throws {
        let view = try v094Source("TankardApp/ContentView.swift")
        let start = try #require(view.range(of: ".onChange(of: store.report != nil) { _, ready in"))
        let block = String(view[start.lowerBound...].prefix(260))
        #expect(block.contains("if store.tab == .discover { openDiscover() }"))
        #expect(block.contains("if store.tab == .services { store.openServices() }"))
        #expect(view.contains("ContentUnavailableView(\"Services needs Homebrew's status first\""))
    }
}

// MARK: an app open now is named before Upgrade runs

// The plan's "These apps will be closed…" note was worked out once, when
// the plan opened. With "Don't quit running apps during upgrades" on it
// names none (brew leaves them open). Turned off while the plan was up
// (or the app opened meanwhile), Upgrade ran without the note, and brew
// quit the app.
@MainActor
struct V094PlanRunningAppsTests {
    @Test func turningDontQuitOffNamesTheAppFirst() async throws {
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.appManagementGate = false
        deps.streamRunner = FakeStreamRunner(log: CallLog()) { _, _ in 0 }
        let settings = testSettings()
        InsightSettings(defaults: settings.defaults).includeSelfUpdatingApps = true
        let store = AppStore(deps: deps, settings: settings)
        store.autoUpdate.conditions = FixedConditions(ac: nil, idle: nil, apps: [V085RunningAppsTests.chrome])
        await store.start()
        try #require(store.packages.contains { $0.name == "google-chrome" && $0.isManualUpgradeTarget })
        store.insights.settings.dontQuitAppsDuringUpgrade = true
        store.requestUpgradeAllPlan()
        let opened = try #require(store.upgradePlan)
        #expect(opened.runningAppsToRun.isEmpty)

        store.insights.settings.dontQuitAppsDuringUpgrade = false
        store.confirmUpgradePlan()
        #expect(store.upgrade == nil, "shows the open app first")
        let plan = try #require(store.upgradePlan)
        #expect(plan.runningAppsToRun == ["Google Chrome"])
        #expect(plan.runningAppsNote?.contains("Google Chrome") == true)
        #expect(plan.changedNote == nil, "the packages didn't change")
        store.confirmUpgradePlan()
        let s = try #require(store.upgrade)
        #expect(await waitUntil { s.isFinished })
    }

    /// Turned on meanwhile: nothing new to name, Upgrade runs at once.
    @Test func turningDontQuitOnRunsAtOnce() async throws {
        var deps = Demo.dependencies(.arm64, pace: 0)
        deps.appManagementGate = false
        deps.streamRunner = FakeStreamRunner(log: CallLog()) { _, _ in 0 }
        let settings = testSettings()
        InsightSettings(defaults: settings.defaults).includeSelfUpdatingApps = true
        let store = AppStore(deps: deps, settings: settings)
        store.autoUpdate.conditions = FixedConditions(ac: nil, idle: nil, apps: [V085RunningAppsTests.chrome])
        await store.start()
        store.requestUpgradeAllPlan()
        #expect(store.upgradePlan?.runningAppsToRun == ["Google Chrome"])
        store.insights.settings.dontQuitAppsDuringUpgrade = true
        store.confirmUpgradePlan()
        let s = try #require(store.upgrade)
        #expect(await waitUntil { s.isFinished })
    }
}
