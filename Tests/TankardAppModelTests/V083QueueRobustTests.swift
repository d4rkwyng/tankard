import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.3 (queue robustness): Stop Now for single runs, waiting for brew's
// lock, the quit guard's interrupted-run offer, and Retry in the sheet.
// Fakes only; the real-brew checks are in V083QueueRobustRealTests.

@MainActor
struct V083StopTests {
    /// A store whose `brew <verb>` streams one line, then runs until cancelled.
    func store(blocking verb: String, log: CallLog = CallLog()) -> AppStore {
        let client = makeClient(FakeInfoRunner(log: log, info: demoIntelInfo()))
        let runner = FakeStreamRunner(log: log, behaviour: { args, out in
            if args.first == verb {
                out(Data("==> Pouring something\n".utf8))
                try await sleepUntilCancelled()
            }
            return 0
        })
        return AppStore(deps: AppStore.Dependencies(makeClient: { client }, streamRunner: runner, cache: nil, logURL: nil))
    }

    @Test func confirmationOnlyWhileBrewChangesAPackage() {
        let f = UpgradeSession.stopNeedsConfirmation
        #expect(f(.install, true, false, false))
        #expect(f(.upgrade, true, false, false))
        #expect(f(.restore, true, false, false))
        #expect(!f(.install, true, true, false), "downloading: safe")
        #expect(!f(.install, true, false, true), "waiting for the lock: nothing runs")
        #expect(!f(.install, false, false, false), "nothing running")
        #expect(!f(.uninstall, true, false, false), "brew defers interrupts while it removes a keg")
        #expect(!f(.cleanup, true, false, false))
    }

    @Test func singleInstallStopsNowAfterConfirming() async throws {
        let log = CallLog()
        let store = store(blocking: "upgrade", log: log)
        await store.start()
        let xz = try #require(store.packages.first { $0.name == "xz" })
        let reads = log.calls.count
        store.startUpgrade([xz])
        let s = try #require(store.upgrade)
        #expect(await waitUntil { s.current != nil })
        #expect(s.total == 1)
        // Pouring (no download seen): asks first, stops nothing yet.
        s.requestStopNow()
        #expect(s.confirmingStop)
        #expect(!s.stopRequested)
        #expect(s.items[0].state == .running)
        s.stopNow()
        #expect(s.statusLine.contains("Stopping xz"))
        #expect(await waitUntil { s.isFinished })
        #expect(s.items[0].state == .cancelled)
        #expect(s.title == "Upgrade stopped")
        // History: one entry, stopped; then the list is read again.
        #expect(await waitUntil { store.history.entries.contains { $0.arguments.first == "upgrade" } })
        #expect(store.history.entries.first { $0.arguments.first == "upgrade" }?.outcome == .cancelled)
        #expect(await waitUntil { log.calls.count > reads + 1 })
    }

    @Test func stopNowWithoutRunningStepNeedsNoConfirmation() async throws {
        let store = store(blocking: "uninstall")
        await store.start()
        let xz = try #require(store.packages.first { $0.name == "xz" })
        store.startSession(.uninstall, packages: [xz])
        let s = try #require(store.upgrade)
        #expect(await waitUntil { s.current != nil })
        s.requestStopNow()
        #expect(!s.confirmingStop)
        #expect(await waitUntil { s.isFinished })
        #expect(s.items[0].state == .cancelled)
    }
}
