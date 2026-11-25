import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.9.4 bug hunt (item 1): user-facing bugs found against fake Homebrew.

// MARK: a quiet scheduled check keeps the refresh failure

// A Refresh whose brew update failed (offline) shows "Last refresh failed"
// and the error banner. A scheduled check (notifications, Auto-update)
// that then also couldn't reach the network is quiet: it shows nothing.
// It used to clear the earlier failure too, so the window said "Updated
// just now" / "Everything is up to date" although no update had succeeded,
// and the saved failure record was deleted.
extension AppStoreTests {
    static let unreachableUpdate: @Sendable ([String], @escaping @Sendable (Data) -> Void) async throws -> Int32 = { args, output in
        guard args.first == "update" else { output(Data("ok\n".utf8)); return 0 }
        output(Data("fatal: unable to access 'https://github.com/Homebrew/brew/': Failed to connect to 127.0.0.1 port 3128\n".utf8))
        return 1
    }

    @Test func aQuietScheduledCheckKeepsTheRefreshFailure() async throws {
        let r = try rig(stream: Self.unreachableUpdate)
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.refresh(manual: true)
        let failed = try #require(r.store.error)
        #expect(r.store.upgradeCheckFailed)
        #expect(r.store.settings.lastUpdateFailure != nil)

        await r.store.refresh(.scheduled)
        #expect(r.store.lastScheduledUpdate?.quiet == .offline)
        #expect(r.log.count("update") == 2)
        #expect(r.store.error == failed)
        #expect(r.store.upgradeCheckFailed)
        #expect(r.store.settings.lastUpdateFailure != nil)
    }

    /// Without an earlier failure a quiet scheduled check still shows nothing.
    @Test func aQuietScheduledCheckAloneShowsNoError() async throws {
        let r = try rig(stream: Self.unreachableUpdate)
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.refresh(.scheduled)
        #expect(r.store.lastScheduledUpdate?.quiet == .offline)
        #expect(r.store.error == nil)
        #expect(!r.store.upgradeCheckFailed)
    }
}
