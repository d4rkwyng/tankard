import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.6 (VM test L2): Pin was offered for a package Homebrew can't read
// (gifgrep from an untrusted tap); `brew pin` failed, and the status bar
// then said "Last refresh failed / Showing the last data Tankard read",
// although only the pin had failed.
@MainActor
struct V086UnreadablePinTests {
    func unreadable() -> Package {
        var p = Package.command("gifgrep")
        p.id = "formula:steipete/tap/gifgrep"
        p.tap = "steipete/tap"
        p.installedVersion = "0.2.0"
        p.unreadable = "Refusing to load formula steipete/tap/gifgrep from untrusted tap steipete/tap."
        return p
    }

    @Test func noPinForAPackageBrewCantRead() {
        let m = ContextMenus.installed(unreadable(), dependents: [], dependencies: [], compileWarning: nil, busy: false, kegPath: nil)
        let ids = m.compactMap { $0.item?.id }
        #expect(!ids.contains("pin"))
        #expect(!ids.contains("unpin"))
        var pinned = unreadable()
        pinned.pinned = true
        let m2 = ContextMenus.installed(pinned, dependents: [], dependencies: [], compileWarning: nil, busy: false, kegPath: nil)
        let ids2 = m2.compactMap { $0.item?.id }
        #expect(!ids2.contains("unpin"))
        #expect(!PinCommands.offered(for: unreadable()))
    }

    @Test func setPinnedRunsNothingForIt() async throws {
        let log = CallLog()
        let client = makeClient(FakeInfoRunner(log: log, info: demoIntelInfo()))
        let deps = AppStore.Dependencies(makeClient: { client }, streamRunner: FakeStreamRunner(log: log) { _, _ in 0 },
                                         cache: nil, logURL: nil)
        let store = AppStore(deps: deps, settings: testSettings())
        await store.refresh(manual: false)
        let before = log.calls.count
        store.setPinned(unreadable(), true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(log.calls.count == before)
    }

    @Test func onlyARefreshErrorSaysTheRefreshFailed() {
        let pin = AppStore.quickError(verb: "Pin", name: "gifgrep", args: ["pin", "gifgrep"],
                                      result: QuickResult(exitCode: 1, lines: ["Error: Refusing to load formula"]))
        #expect(!pin.fromRefresh)
        #expect(StoreError(title: "Refresh failed", detail: "", fromRefresh: true).fromRefresh)
    }
}
