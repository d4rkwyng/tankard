import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.4 fix from the 0.8.3 test pass (F5): Homebrew-menu items stayed
// enabled during a run and with a sheet up. They now share one gate,
// `menuActionsBlocked` (a run, shown or hidden, or any sheet), and History
// only `isSheetPresented`.

@MainActor
struct V084MenuGateTests {
    func demo() async -> AppStore {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: testSettings())
        await store.start()
        return store
    }

    @Test func idleNothingBlocked() async {
        let store = await demo()
        #expect(!store.isSheetPresented)
        #expect(!store.menuActionsBlocked)
    }

    @Test func everySheetBlocks() async throws {
        let store = await demo()
        let leaf = try #require(store.packages.first { $0.kind == .formula && store.dependents(of: $0).isEmpty })
        let opens: [(String, () -> Void, () -> Void)] = [
            ("history", { store.openHistory() }, { store.toolSheet = nil }),
            ("health", { store.openHealth() }, { store.toolSheet = nil }),
            ("uninstall", { store.requestUninstall(leaf) }, { store.uninstallCandidate = nil }),
            ("cleanup", { store.showCleanupSheet = true }, { store.showCleanupSheet = false }),
            ("management", { store.requestManagement(.uninstall) }, { store.managementSheet = nil }),
            ("restore points", { store.openRestorePoints() }, { store.restorePoints.isShowing = false }),
            ("auto-update log", { store.showAutoUpdateLog = true }, { store.showAutoUpdateLog = false }),
            ("self-update", { store.showSelfUpdate = true }, { store.showSelfUpdate = false }),
            ("activity", { store.showUpgradeSheet = true }, { store.showUpgradeSheet = false }),
        ]
        for (name, open, close) in opens {
            open()
            #expect(store.isSheetPresented, "\(name)")
            #expect(store.menuActionsBlocked, "\(name)")
            close()
            #expect(!store.isSheetPresented, "\(name) closed")
        }
        // Discover's compile-install confirmation.
        let d = try #require(store.openDiscover())
        d.confirmInstall = "formula:x"
        #expect(store.isSheetPresented)
        d.confirmInstall = nil
        #expect(!store.menuActionsBlocked)
    }

    @Test func aRunBlocksEvenWithItsSheetHidden() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 5), settings: testSettings())
        await store.start()
        let p = try #require(store.packages.first { $0.isManualUpgradeTarget })
        store.startSession(.upgrade, packages: [p], skipGate: true)
        #expect(store.isUpgrading)
        #expect(store.menuActionsBlocked)
        store.showUpgradeSheet = false // Hide
        #expect(!store.isSheetPresented) // History may open…
        #expect(store.menuActionsBlocked) // …nothing that runs brew may
        store.upgrade?.stopNow()
        #expect(await waitUntil { store.upgrade?.isFinished == true })
    }
}
