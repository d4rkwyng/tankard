import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.8 (gauntlet 26, P3): after a failed Refresh (brew update offline),
// Installed said "Updated just now · Last refresh failed", but a later
// read without brew update (window to the front) cleared the failure, and
// the status bar then said only "Updated just now". The failure now stays
// until the next brew update or Dismiss.

extension AppStoreTests {
    static let offlineUpdate: @Sendable ([String], @escaping @Sendable (Data) -> Void) async throws -> Int32 = { args, output in
        guard args.first == "update" else { output(Data("ok\n".utf8)); return 0 }
        output(Data("Fetching /opt/homebrew failed!\n".utf8))
        return 1
    }

    @Test func aReadWithoutUpdateKeepsTheUpdateFailure() async throws {
        let r = try rig(stream: Self.offlineUpdate)
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.refresh(manual: true)
        let failed = try #require(r.store.error)
        #expect(failed.fromRefresh)
        #expect(failed.detail.contains("Fetching /opt/homebrew failed!"))
        await r.store.refresh(manual: false)
        #expect(r.log.count("update") == 1)
        #expect(r.store.error == failed)
    }

    @Test func dismissOrAGoodUpdateClearsIt() async throws {
        let r = try rig(stream: Self.offlineUpdate)
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.store.refresh(manual: true)
        #expect(r.store.error != nil)
        r.store.dismissError()
        await r.store.refresh(manual: false)
        #expect(r.store.error == nil)

        let ok = try rig()
        defer { try? FileManager.default.removeItem(at: ok.dir) }
        ok.store.updateFailure = StoreError(title: "brew update failed", detail: "x")
        await ok.store.refresh(manual: true)
        #expect(ok.store.error == nil)
        await ok.store.refresh(manual: false)
        #expect(ok.store.error == nil)
    }
}
