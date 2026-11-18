import Foundation
import Observation
import Testing
import TankardCore
@testable import TankardAppModel

// v0.7, app side: the Taps sheet through demo mode (tap-info, Add, Remove,
// Trust through the queue and History), the queue argv, Show Installed's
// "tap:" search, the Brewfile plan's Add Tap, and equal writes dropped.

@MainActor
struct V07TapsAppTests {
    @Test func openReadsTheList() async throws {
        let store = AppStore(deps: Demo.dependencies(.arm64, pace: 0))
        await store.start()
        store.openTaps()
        #expect(store.toolSheet == .taps)
        #expect(await waitUntil { store.taps.phase == .ready })
        #expect(store.taps.taps.count == 5)
        store.taps.setFilter(.thirdParty)
        #expect(store.taps.visibleTaps.map(\.name) == ["mull-project/mull", "steipete/tap", "yakitrak/yakitrak"])
        store.taps.setFilter(.official)
        #expect(store.taps.visibleTaps.allSatisfy { $0.official })
    }

    @Test func addRunsBrewTapThroughTheQueueAndHistory() async throws {
        let store = AppStore(deps: Demo.dependencies(.arm64, pace: 0))
        await store.start()
        store.openTaps()
        #expect(await waitUntil { store.taps.phase == .ready })
        #expect(store.taps.requestAdd(name: "bad name") == .badName)
        #expect(store.taps.pendingAdd == nil)
        #expect(store.taps.requestAdd(name: "me/tools", url: "git@github.com:me/homebrew-tools.git") == nil)
        let req = try #require(store.taps.pendingAdd)
        #expect(req.command == "brew tap me/tools git@github.com:me/homebrew-tools.git")
        #expect(req.warning.contains("third-party tap"))
        #expect(!TapAddRequest(name: "homebrew/cask-fonts").warning.contains("third-party"))
        store.confirmAddTap()
        #expect(store.taps.pendingAdd == nil)
        #expect(store.toolSheet == nil)
        #expect(await waitUntil { store.upgrade != nil })
        let session = try #require(store.upgrade)
        #expect(session.action == .tap)
        #expect(session.items.first?.command.arguments == ["tap", "me/tools", "git@github.com:me/homebrew-tools.git"])
        #expect(await waitUntil { store.upgrade?.isFinished == true })
        #expect(await waitUntil { store.history.entries.contains { $0.arguments.first == "tap" } })
        let e = try #require(store.history.entries.first { $0.arguments.first == "tap" })
        #expect(e.category == .taps && e.outcome == .succeeded && !e.canRetry)
        await store.taps.load()
        #expect(store.taps.taps.contains { $0.name == "me/tools" })
    }

    @Test func removeIsBlockedWhileInstalledAndOtherwiseUntaps() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0))
        await store.start()
        store.openTaps()
        #expect(await waitUntil { store.taps.phase == .ready })
        let core = try #require(store.taps.taps.first { $0.name == "homebrew/core" })
        #expect(core.tapped && core.remote == Intelbrew.coreRemote)
        #expect(store.installedCount(from: core) == store.packages.count)
        if case .inUse(let names) = store.taps.requestRemove(core, packages: store.packages) {
            #expect(names.count == store.packages.count)
        } else {
            Issue.record("core should be blocked")
        }
        #expect(store.taps.pendingRemove == nil)
        store.confirmRemoveTap() // nothing pending: nothing runs
        #expect(store.upgrade == nil)

        let own = try #require(store.taps.taps.first { $0.name == "d4rkwyng/tap" })
        #expect(store.taps.requestRemove(own, packages: store.packages) == .allowed)
        #expect(store.taps.pendingRemove == own)
        store.confirmRemoveTap()
        #expect(await waitUntil { store.upgrade != nil })
        #expect(store.upgrade?.action == .untap)
        // 0.8.5 (L8): a third-party tap's trust is removed first.
        #expect(store.upgrade?.items.map(\.command.arguments) == [["untrust", "--tap", "d4rkwyng/tap"], ["untap", "d4rkwyng/tap"]])
        #expect(await waitUntil { store.upgrade?.isFinished == true })
        await store.taps.load()
        #expect(!store.taps.taps.contains { $0.name == "d4rkwyng/tap" })
    }

    @Test func trustRunsThroughTheQueue() async throws {
        let store = AppStore(deps: Demo.dependencies(.arm64, pace: 0))
        await store.start()
        store.openTaps()
        #expect(await waitUntil { store.taps.phase == .ready })
        let mull = try #require(store.taps.taps.first { $0.name == "mull-project/mull" })
        #expect(mull.trusted == false)
        store.taps.requestTrust(mull)
        store.confirmTrustTap()
        #expect(await waitUntil { store.taps.taps.first { $0.name == "mull-project/mull" }?.trusted == true })
        #expect(await waitUntil { store.history.entries.contains { $0.arguments == ["trust", "--tap", "mull-project/mull"] } })
        // Official taps have nothing to trust.
        let core = try #require(store.taps.taps.first { $0.name == "homebrew/core" })
        store.taps.requestTrust(core)
        #expect(store.taps.pendingTrust == nil)
    }

    @Test func sessionArgvForTapAndUntap() {
        let p = AppStore.tapPlaceholder(name: "me/tools", url: "https://e.com/me/tools.git")
        #expect(BrewCommands.arguments(.tap, for: p) == ["tap", "me/tools", "https://e.com/me/tools.git"])
        #expect(BrewCommands.arguments(.untap, for: p) == ["untap", "me/tools"])
        let q = AppStore.tapPlaceholder(name: "me/tools", url: nil)
        #expect(BrewCommands.arguments(.tap, for: q) == ["tap", "me/tools"])
        #expect(HistoryCategory(arguments: ["untrust", "--tap", "x/y"]) == .taps)
        #expect(HistoryFilter.menu.contains(.category(.taps)))
    }

    @Test func showInstalledFiltersByTap() async throws {
        let store = AppStore(deps: Demo.dependencies(.arm64, pace: 0))
        await store.start()
        store.openTaps()
        #expect(await waitUntil { store.taps.phase == .ready })
        let cask = TapInfo(name: "homebrew/cask", official: true, tapped: false)
        store.filter = .upgrades
        store.showInstalled(from: cask)
        #expect(store.search == "tap:homebrew/cask" && store.filter == .all && store.tab == .installed)
        #expect(store.toolSheet == nil)
        #expect(!store.visiblePackages.isEmpty)
        #expect(store.visiblePackages.allSatisfy { $0.kind == .cask })
        #expect(RelatedSearch("tap: steipete/tap") == .tap("steipete/tap"))
        #expect(RelatedSearch("tap:") == nil)
    }

    @Test func brewfilePlanAddsTapsThroughTheSameConfirmation() async throws {
        let store = AppStore(deps: Demo.dependencies(.arm64, pace: 0))
        await store.start()
        #expect(store.taps.requestAdd(name: "steipete/tap", source: .brewfile) == nil)
        #expect(store.taps.pendingAdd?.source == .brewfile)
        store.confirmAddTap()
        #expect(await waitUntil { store.upgrade?.action == .tap })
        #expect(store.upgrade?.items.first?.command.arguments == ["tap", "steipete/tap"])
    }

    @Test func equalWritesAreDropped() async throws {
        let taps = TapsStore()
        func notifies(_ write: () -> Void) -> Bool {
            let notified = Flag()
            withObservationTracking { _ = (taps.selection, taps.filter, taps.pendingAdd, taps.phase, taps.taps) }
                onChange: { notified.set() }
            write()
            return notified.value
        }
        #expect(!notifies { taps.select(nil) })
        #expect(!notifies { taps.setFilter(.all) })
        #expect(!notifies { taps.cancelPending() })
        #expect(!notifies { taps.setPhase(.idle) })
        #expect(!notifies { taps.setTaps([]) })
        #expect(notifies { taps.requestAdd(name: "a/b") })
        #expect(!notifies { taps.requestAdd(name: "a/b") })
        #expect(notifies { taps.setFilter(.official) })
        #expect(notifies { taps.cancelPending() })
    }

    @Test func demoFixtureMatchesTheTestFixture() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("TankardCoreTests/Fixtures")
        let original = try Data(contentsOf: fixtures.appendingPathComponent("arm64-tap-info.json"))
        #expect(Demo.fixtureData("arm64-tap-info") == original)
    }
}
