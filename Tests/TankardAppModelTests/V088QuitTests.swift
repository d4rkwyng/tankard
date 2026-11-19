import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.8 (gauntlets 15 and 26): quitting and relaunching over a sheet, the
// "Run again" offer after an App Management relaunch, the run sheet in a
// short window, and a concurrent install of the same package.

@MainActor
struct V088QuitTests {
    static let anybar = CatalogEntry(kind: .cask, name: "anybar", fullName: "anybar", tap: "homebrew/cask", desc: nil,
                                     version: "1.0", bottle: .cask)

    func deps(cache: StatusCache? = nil, relaunch: (@MainActor @Sendable () -> Bool)? = nil,
              hold: Latch? = nil) -> AppStore.Dependencies {
        var deps = Demo.dependencies(.arm64, pace: 0.01)
        deps.relaunch = relaunch
        deps.cache = cache
        if let hold {
            deps.appManagementGate = false
            deps.streamRunner = FakeStreamRunner(log: CallLog()) { args, _ in
                if args.first == "upgrade" { await hold.wait() }
                return 0
            }
        }
        return deps
    }

    func store(_ deps: AppStore.Dependencies, settings: AppSettings = testSettings()) async -> AppStore {
        let store = AppStore(deps: deps, settings: settings)
        await store.start()
        return store
    }

    /// An upgrade that runs at once (no plan, no notes).
    func plain(_ store: AppStore) throws -> Package {
        try #require(store.packages.first {
            $0.isManualUpgradeTarget && $0.kind == .formula && $0.caveats == nil
                && !UpgradePlan(packages: [$0], classifier: store.deps.classifier).needsConfirmation
        })
    }

    func tempCache() -> StatusCache {
        StatusCache(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("tankard-v088-\(UUID().uuidString)/status.json"))
    }

    // MARK: 1. the relaunch wedge

    /// "Relaunch Tankard" cleared the App Management prompt but left the
    /// activity sheet's flag set: SwiftUI put the (empty) sheet back after
    /// AppKit ended it, and termination was refused under it.
    @Test func relaunchLeavesNoSheetToPutBack() async throws {
        let settings = testSettings()
        let store = await store(deps(relaunch: { true }), settings: settings)
        store.startInstall(Self.anybar)
        #expect(store.appManagementPrompt?.reason == .firstUse)
        #expect(store.showUpgradeSheet)
        store.appManagementDone()
        #expect(store.appManagementPrompt?.stage == .relaunch)
        store.appManagementRelaunch()
        #expect(store.appManagementPrompt == nil)
        #expect(!store.showUpgradeSheet)
        #expect(!store.showsActivitySheet)
        #expect(!store.isSheetPresented)
        #expect(store.terminating)
        #expect(settings.appManagementPendingRetry != nil)
    }

    /// A relaunch whose helper didn't start keeps Tankard usable (offers
    /// allowed) and says so.
    @Test func aRelaunchThatGivesUpAllowsSheetsAgain() async throws {
        let store = await store(deps(relaunch: { true }))
        store.prepareForTermination()
        #expect(store.terminating)
        store.relaunchGaveUp()
        #expect(!store.terminating)
        #expect(store.error != nil)
    }

    // MARK: 2. the Run again offer

    /// The saved offer is shown at the next launch even when the cached
    /// list is fresh (the launch used to skip the read the offer hung on,
    /// so it showed after some later, unrelated run instead).
    @Test func theOfferShowsAtLaunchWithAFreshCache() async throws {
        let cache = tempCache()
        let settings = testSettings()
        let first = await store(deps(cache: cache), settings: settings)
        #expect(first.refreshesCompleted == 1)

        // Control: a launch with nothing pending shows the cache, no read.
        let plain = await store(deps(cache: cache), settings: settings)
        #expect(plain.refreshesCompleted == 0)
        #expect(plain.appManagementResume == nil)

        settings.appManagementPendingRetry = AppManagementPendingRetry(
            action: .install, packages: [Self.anybar.asPackage()], savedAt: Date()).encoded()
        let next = await store(deps(cache: cache), settings: settings)
        // Shown by the launch itself, once its read has ended.
        #expect(next.refreshesCompleted == 1)
        let offer = try #require(next.appManagementResume)
        #expect(offer.action == .install)
        #expect(offer.packages.map(\.name) == ["anybar"])
        #expect(next.showUpgradeSheet)
        #expect(settings.appManagementPendingRetry == nil) // once
    }

    /// Once dismissed (or never shown), it doesn't come back with a later
    /// run's read: a reinstall's Stop Now used to bring it up, claiming
    /// "Tankard relaunched".
    @Test func theOfferNeverAttachesToALaterRun() async throws {
        let settings = testSettings()
        let store = await store(deps(), settings: settings)
        // Saved after this launch's read (as by another copy of Tankard).
        settings.appManagementPendingRetry = AppManagementPendingRetry(
            action: .install, packages: [Self.anybar.asPackage()], savedAt: Date()).encoded()
        let p = try plain(store)
        let reads = store.refreshesCompleted
        store.startUpgrade([p])
        let s = try #require(store.upgrade)
        #expect(await waitUntil { s.isFinished })
        #expect(await waitUntil { store.refreshesCompleted > reads && !store.isRefreshing })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(store.appManagementResume == nil)
        #expect(store.upgrade === s)
    }

    // MARK: 3. Quit over a sheet

    @Test func quitWithNothingRunningClosesTheSheets() async throws {
        let store = await store(deps())
        let p = try plain(store)
        store.startUpgrade([p])
        let s = try #require(store.upgrade)
        #expect(await waitUntil { s.isFinished && !store.isRefreshing })
        // The finished "Upgrade complete" sheet, and notes over it.
        #expect(store.showUpgradeSheet)
        store.insights.postInstallNotes = PostInstallNotes(action: .install, notes: [
            .init(id: "x", name: "x", version: "1", kind: .formula, text: "caveat")])
        #expect(store.quitStep == .closeSheetsAndQuit)
        store.prepareForTermination()
        #expect(!store.showUpgradeSheet)
        #expect(!store.isSheetPresented)
        #expect(store.insights.postInstallNotes == nil)
        // Notes arriving while quitting (the run's last read) wait.
        store.offerPostInstallNotes(for: s)
        #expect(store.insights.postInstallNotes == nil)
        #expect(store.insights.pendingNotes == nil)
        store.terminationCancelled()
        #expect(!store.terminating)
    }

    @Test func quitWhileBrewRunsAsksFirstThenCloses() async throws {
        let hold = Latch()
        let store = await store(deps(hold: hold))
        let p = try plain(store)
        store.startUpgrade([p])
        let s = try #require(store.upgrade)
        #expect(await waitUntil { s.current != nil })
        guard case .ask(let prompt) = store.quitStep else {
            Issue.record("expected the quit guard's question, got \(store.quitStep)")
            hold.release()
            return
        }
        #expect(prompt.name == p.name)
        // Quit Now: brew is stopped, then every sheet closes, the
        // still-shown run's sheet too.
        let quit = Flag()
        store.prepareToQuit(.now) { quit.set() }
        hold.release()
        #expect(await waitUntil { quit.value })
        #expect(store.quitStep == .closeSheetsAndQuit)
        store.prepareForTermination()
        #expect(!store.showUpgradeSheet)
        #expect(!store.isSheetPresented)
    }

    /// The offers a quit would otherwise put up are held while quitting.
    @Test func noOfferWhileQuitting() async throws {
        let settings = testSettings()
        let store = await store(deps(), settings: settings)
        store.prepareForTermination()
        settings.appManagementPendingRetry = AppManagementPendingRetry(
            action: .install, packages: [Self.anybar.asPackage()], savedAt: Date()).encoded()
        #expect(!store.resumeAppManagementRetry())
        #expect(store.appManagementResume == nil)
        #expect(!store.showUpgradeSheet)
    }

    // MARK: 5. the run sheet in a short window

    @Test func theRunSheetFitsTheWindow() {
        #expect(SessionSheetLayout.maxHeight(room: nil) == nil)
        #expect(SessionSheetLayout.maxHeight(room: 0) == nil)
        // Gauntlet 15: 660 pt of room, the sheet was 721.
        #expect(SessionSheetLayout.maxHeight(room: 660) == 644)
        #expect(SessionSheetLayout.maxHeight(room: 200) == SheetHeight.minimum)
        #expect(SessionSheetLayout.logMinHeight < SessionSheetLayout.logHeight)
    }

    // MARK: 6. a concurrent install of the same package

    @Test func aConcurrentInstallIsExplained() {
        let lines = [
            "✘ Bottle openjdk (27.0.1.1)",
            "Error: Bottle destination already exists: /opt/homebrew/var/homebrew/tmp/.cellar/openjdk/27.0.1.1",
        ]
        #expect(BrewFailure.classify(lines) == .concurrentInstall)
        #expect(BrewFailureKind.concurrentInstall.title == "Another Homebrew run was installing it")
        #expect(BrewFailureKind.concurrentInstall.explanation.contains("Retry"))
        #expect(UpgradeSession.nextStep(.concurrentInstall)?.contains("Retry") == true)
        // Still the lock when brew says so.
        #expect(BrewFailure.classify(["Error: A `brew install` process has already locked /opt/homebrew/Cellar/x"]) == .locked)
    }

    // MARK: owner report: the menu-bar panel's version pairs

    /// The panel shows the new version whole and cuts the old one, so it
    /// needs the pair in two halves.
    @Test func panelVersionPairSplitsIntoOldAndNew() {
        let r = MenuBarSummary.Row(id: "cask:chatgpt", name: "chatgpt",
                                   versions: MenuBarSummary.versionPair("26.1111.21308,1762909290", "26.1111.71704,1763142180"),
                                   compiles: false, isCask: true)
        #expect(r.from == "26.1111.21308")
        #expect(r.to == "26.1111.71704")
        let plain = MenuBarSummary.Row(id: "f", name: "gh", versions: "2.104.0 → 2.105.0", compiles: false, isCask: false)
        #expect(plain.from == "2.104.0")
        #expect(plain.to == "2.105.0")
        let odd = MenuBarSummary.Row(id: "x", name: "x", versions: "1.0", compiles: false, isCask: false)
        #expect(odd.from == "1.0")
        #expect(odd.to == "")
    }
}
